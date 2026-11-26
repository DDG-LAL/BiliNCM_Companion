#requires -Version 5.1
<#
    BiliNCM-Bot 运行日志捕获
    ------------------------------------------------------------------
    轮询 http://localhost:5555/api/logs，把新出现的日志追加到
    bot-runtime.log。日志只在 bot 运行时存在内存中，所以需要这个
    独立进程在后台持续抓取。

    不修改 bot，不读取 Cookie。
#>

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [string]$OutFile = '',
    [int]$IntervalSeconds = 2,
    [int]$IdleExitSeconds = 45,
    [long]$MaxLogBytes = 5242880
)

$ErrorActionPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $Root 'bot-runtime.log'
}

function Remove-AnsiCodes {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $esc = [char]27
    return ($Text -replace ($esc + '\[[0-9;?]*[ -/]*[@-~]'), '')
}

function Rotate-LogIfNeeded {
    param([string]$Path, [long]$MaxBytes)
    if ($MaxBytes -le 0) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        if ((Get-Item -LiteralPath $Path).Length -lt $MaxBytes) { return $false }
        $archive = $Path + '.1'
        if (Test-Path -LiteralPath $archive) {
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $Path -Destination $archive -Force
        return $true
    } catch {
        return $false
    }
}

function Get-SeenLogKeys {
    param([string]$Path)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return (,$set) }
        $lines = @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))
        $start = [Math]::Max(0, $lines.Count - 2000)
        for ($i = $start; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\[([^\]]*)\] \[([^\]]*)\] (.*)$') {
                [void]$set.Add($matches[1] + '|' + $matches[2] + '|' + $matches[3])
            }
        }
    } catch { }
    return (,$set)
}

function Test-LegacyLogFormat {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $reader = [IO.File]::OpenText($Path)
        try {
            for ($i = 0; $i -lt 20 -and -not $reader.EndOfStream; $i++) {
                $line = $reader.ReadLine()
                # Old capture wrote a whole batch as one line, so the first
                # bracket contains several space-separated timestamps.
                if ($line -match '^\[[^\]]*\s[^\]]*\]') { return $true }
            }
        } finally {
            $reader.Dispose()
        }
    } catch { }
    return $false
}

function Get-BotLogEntries {
    param([string]$Json)
    $items = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Json)) { return $items.ToArray() }

    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $Json } catch { return $items.ToArray() }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($parsed)
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($null -eq $item) { continue }

        if ($item -is [System.Array]) {
            foreach ($child in $item) { $queue.Enqueue($child) }
            continue
        }

        if ($item -is [string]) {
            $text = $item.Trim()
            if ($text.StartsWith('[') -or $text.StartsWith('{')) {
                try { $queue.Enqueue((ConvertFrom-Json -InputObject $text)) } catch { }
            }
            continue
        }

        $timeProp = $item.PSObject.Properties['Time']
        $colorProp = $item.PSObject.Properties['Color']
        $messageProp = $item.PSObject.Properties['Message']

        # The API normally returns an array of entries. PowerShell 5.1 can
        # hand the array back as one object, so handle both shapes.
        if ($timeProp -and $colorProp -and $messageProp -and $timeProp.Value -is [System.Array]) {
            $times = @($timeProp.Value)
            $colors = @($colorProp.Value)
            $messages = @($messageProp.Value)
            $count = [Math]::Min($times.Count, [Math]::Min($colors.Count, $messages.Count))
            for ($i = 0; $i -lt $count; $i++) {
                [void]$items.Add([pscustomobject]@{
                    Time    = [string]$times[$i]
                    Color   = [string]$colors[$i]
                    Message = [string]$messages[$i]
                })
            }
            continue
        }

        if ($timeProp -and $colorProp -and $messageProp) {
            [void]$items.Add([pscustomobject]@{
                Time    = [string]$timeProp.Value
                Color   = [string]$colorProp.Value
                Message = [string]$messageProp.Value
            })
            continue
        }

        $logsProp = $item.PSObject.Properties['logs']
        if ($logsProp -and $null -ne $logsProp.Value) {
            $queue.Enqueue($logsProp.Value)
        }
    }
    return $items.ToArray()
}

# 同一时间只允许一个捕获进程，避免重复写日志。
$mutex = New-Object System.Threading.Mutex($false, 'Local\BiliNCM-BotLogCapture')
$haveMutex = $false
try {
    try { $haveMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
    if (-not $haveMutex) { exit 0 }

    if (Test-LegacyLogFormat -Path $OutFile) {
        $legacyArchive = $OutFile + '.1'
        try {
            if (Test-Path -LiteralPath $legacyArchive) {
                Remove-Item -LiteralPath $legacyArchive -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $OutFile -Destination $legacyArchive -Force
        } catch { }
    }
    $null = Rotate-LogIfNeeded -Path $OutFile -MaxBytes $MaxLogBytes
    $seen = Get-SeenLogKeys -Path $OutFile
    $lastBotSeen = Get-Date
    $nextRotateCheck = (Get-Date).AddSeconds(60)

    while ($true) {
        if ((Get-Date) -ge $nextRotateCheck) {
            $null = Rotate-LogIfNeeded -Path $OutFile -MaxBytes $MaxLogBytes
            $nextRotateCheck = (Get-Date).AddSeconds(60)
        }

        $bot = @(Get-Process -Name 'BiliNCM-Bot' -ErrorAction SilentlyContinue)

        if ($bot.Count -eq 0) {
            if (((Get-Date) - $lastBotSeen).TotalSeconds -ge $IdleExitSeconds) {
                break
            }
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        $lastBotSeen = Get-Date

        try {
            $resp = Invoke-WebRequest -Uri 'http://localhost:5555/api/logs' -UseBasicParsing -TimeoutSec 3
            $json = ''
            try {
                if ($resp.RawContentStream) {
                    $json = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
                }
            } catch { }
            if ([string]::IsNullOrWhiteSpace($json)) {
                $json = [string]$resp.Content
            }

            $entries = @(Get-BotLogEntries -Json $json)
            foreach ($entry in $entries) {
                $time = (Remove-AnsiCodes ([string]$entry.Time)).Trim()
                $color = (Remove-AnsiCodes ([string]$entry.Color)).Trim()
                $message = Remove-AnsiCodes ([string]$entry.Message)
                $message = $message -replace "`r`n", "`n" -replace "`r", "`n"
                $message = $message -replace "`n", ' / '
                if ([string]::IsNullOrWhiteSpace($time)) { $time = '--' }
                if ([string]::IsNullOrWhiteSpace($color)) { $color = 'Gray' }
                $key = $time + '|' + $color + '|' + $message

                if ($seen.Add($key)) {
                    $line = '[{0}] [{1}] {2}' -f $time, $color, $message
                    # 即使 bot 以后把 Cookie 写进日志，也不把它落盘。
                    $line = $line -replace '(?i)(SESSDATA\s*=\s*)[^;\s]+', '$1<redacted>'
                    $line = $line -replace '(?i)(BiliCookie\s*[=:]\s*)[^\r\n]+', '$1<redacted>'
                    Add-Content -LiteralPath $OutFile -Value $line -Encoding UTF8
                }
            }
        } catch { }

        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    if ($haveMutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    try { $mutex.Dispose() } catch { }
}
