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
    [int]$IdleExitSeconds = 45
)

$ErrorActionPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $Root 'bot-runtime.log'
}

# 同一时间只允许一个捕获进程，避免重复写日志。
$mutex = New-Object System.Threading.Mutex($false, 'Local\BiliNCM-BotLogCapture')
$haveMutex = $false
try {
    try { $haveMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
    if (-not $haveMutex) { exit 0 }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $lastBotSeen = Get-Date

    while ($true) {
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

            $logs = @($json | ConvertFrom-Json)
            foreach ($entry in $logs) {
                $time = [string]$entry.Time
                $color = [string]$entry.Color
                $message = [string]$entry.Message
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
