#requires -Version 5.1
<#
    BiliNCM-Bot CDP 启动包装器
    ------------------------------------------------------------------
    作用：
      1. 先检查网易云是否已经以 --remote-debugging-port 启动；
      2. 只有在端口/目标页不可用时才提示，确认后才由包装器重启网易云；
         （BiliNCM-Bot 自身启动时也可能重启网易云，包装器无法阻止）
      3. 启动 bot，并在 bot 自身启动重启之后再次检查 CDP；
      4. 启动 bot 日志捕获，把 /api/logs 追加到 bot-runtime.log；
      5. 启动 OBS 覆盖层（http://127.0.0.1:5566/），显示当前歌曲和待播点歌。

    约束：
      - 不修改 BiliNCM-Bot.exe；
      - 不修改 current\ 下的程序文件；
      - 本脚本和生成的日志都放在 BiliNCM-Bot-win-Portable 根目录。

    常用用法：
      启动点歌机.cmd                正常启动（推荐）
      关闭点歌机.cmd                彻底关闭点歌机
      启动点歌机.cmd -CheckOnly     只检查，不提示、不重启、不启动
      调试登录.cmd                  登录诊断（包装器会继续负责 CDP 检查）
#>

[CmdletBinding()]
param(
    [int]$CdpPort = 9222,
    [string]$NcmExe = '',
    [int]$WaitSeconds = 30,
    [switch]$CheckOnly,
    [switch]$SkipLoginCheck,
    [switch]$NoLogCapture,
    [switch]$DebugLogin,
    [switch]$StopBot,
    [switch]$ForceStop
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::InputEncoding  = [Text.Encoding]::UTF8
} catch { }

$Root          = $PSScriptRoot
$Launcher      = Join-Path $Root 'BiliNCM-Bot.exe'
$CurrentExe    = Join-Path $Root 'current\BiliNCM-Bot.exe'
$LoginScript   = Join-Path $Root 'BiliLoginFix.ps1'
$CaptureScript = Join-Path $Root 'Capture-BotLogs.ps1'
$CompanionScript = Join-Path $Root 'BiliNCM-Companion.ps1'
$CompanionLog = Join-Path $Root 'companion.log'
$OverlayScript = Join-Path $Root 'BiliNCM-Overlay.ps1'
$OverlayLog    = Join-Path $Root 'overlay.log'
$OverlayStateFile = Join-Path $Root 'overlay-state.json'
$OverlayPort   = 5566
$LauncherLog   = Join-Path $Root 'launcher.log'
$BotRuntimeLog = Join-Path $Root 'bot-runtime.log'

$script:LogToFile = -not $CheckOnly

# ----------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------
function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
}

function Write-Info2([string]$Text) {
    Write-Host ('  ' + $Text) -ForegroundColor Gray
    Write-LauncherLog $Text 'INFO'
}

function Write-Ok2([string]$Text) {
    Write-Host ('  ' + $Text) -ForegroundColor Green
    Write-LauncherLog $Text 'OK'
}

function Write-Warn3([string]$Text) {
    Write-Host ('  ' + $Text) -ForegroundColor Yellow
    Write-LauncherLog $Text 'WARN'
}

function Write-Err2([string]$Text) {
    Write-Host ('  ' + $Text) -ForegroundColor Red
    Write-LauncherLog $Text 'ERROR'
}

function Write-LauncherLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    if (-not $script:LogToFile) { return }
    try {
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $LauncherLog -Value $line -Encoding UTF8
    } catch { }
}

function Read-YesNo {
    param(
        [string]$Question,
        [bool]$DefaultYes = $false
    )
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host ('  ' + $Question + ' ' + $suffix)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Warn3 '请输入 y 或 n。'
    }
}

# ----------------------------------------------------------------------
# 基础检查
# ----------------------------------------------------------------------
function Test-TcpPort {
    param(
        [int]$Port,
        [int]$TimeoutMs = 800
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Invoke-Utf8Http {
    param(
        [string]$Url,
        [int]$TimeoutSec = 3
    )
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
    try {
        if ($resp.RawContentStream) {
            return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        }
    } catch { }
    return [string]$resp.Content
}

function Test-OverlayHealth {
    try {
        $text = Invoke-Utf8Http -Url ("http://127.0.0.1:{0}/health" -f $OverlayPort) -TimeoutSec 2
        return ([string]$text -match '"ok"\s*:\s*true')
    } catch {
        return $false
    }
}

function Get-CdpSnapshot {
    param([int]$TimeoutSec = 2)

    $snap = [pscustomobject]@{
        PortOpen       = $false
        JsonOk         = $false
        Targets        = @()
        OrpheusTargets = @()
        Error          = ''
    }

    if (-not (Test-TcpPort -Port $CdpPort -TimeoutMs 800)) {
        $snap.Error = "端口 $CdpPort 未监听"
        return $snap
    }

    $snap.PortOpen = $true
    try {
        $text = Invoke-Utf8Http -Url ("http://127.0.0.1:{0}/json" -f $CdpPort) -TimeoutSec $TimeoutSec
        $targets = @($text | ConvertFrom-Json)
        $snap.Targets = $targets
        $snap.JsonOk = $true
        $snap.OrpheusTargets = @($targets | Where-Object {
            $_.type -eq 'page' -and
            ([string]$_.url -match 'orpheus') -and
            (-not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl))
        })
    } catch {
        $snap.Error = $_.Exception.Message
    }
    return $snap
}

function Get-NcmProcessList {
    return @(Get-CimInstance Win32_Process -Filter "Name='cloudmusic.exe'" -ErrorAction SilentlyContinue)
}

function Get-NcmMainProcess {
    $procs = Get-NcmProcessList
    $main = @($procs | Where-Object {
        ([string]$_.CommandLine) -notmatch '--type='
    })
    if ($main.Count -gt 0) { return $main[0] }
    return $null
}

function Get-BotProcessList {
    return @(Get-Process -Name 'BiliNCM-Bot' -ErrorAction SilentlyContinue)
}

function Resolve-NcmExe {
    param([string]$Preferred = '')

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($Preferred) { $candidates.Add($Preferred) }

    $main = Get-NcmMainProcess
    if ($main -and $main.ExecutablePath) {
        $candidates.Add([string]$main.ExecutablePath)
    }

    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Netease\CloudMusic\cloudmusic.exe'))
    }

    try {
        $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
        if ($programFilesX86) {
            $candidates.Add((Join-Path $programFilesX86 'Netease\CloudMusic\cloudmusic.exe'))
        }
    } catch { }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        try {
            $items = @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)
            foreach ($item in $items) {
                if ([string]$item.DisplayName -match '网易云音乐|NetEase Cloud Music') {
                    $loc = [string]$item.InstallLocation
                    if ($loc) {
                        $candidates.Add((Join-Path $loc 'cloudmusic.exe'))
                    }
                    $icon = [string]$item.DisplayIcon
                    if ($icon -match '^"?(.+?cloudmusic\.exe)') {
                        $candidates.Add($matches[1].Trim('"'))
                    }
                }
            }
        } catch { }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $candidate = $candidate.Trim('"')
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Show-NcmDiagnostics {
    Write-Head '诊断信息'

    $snap = Get-CdpSnapshot -TimeoutSec 2
    $portText = if ($snap.PortOpen) { '已监听' } else { '未监听' }
    Write-Info2 ("CDP 端口 {0}: {1}" -f $CdpPort, $portText)
    if ($snap.JsonOk) {
        if ($snap.Targets.Count -eq 0) {
            Write-Warn3 '/json 返回了空目标列表。'
        } else {
            foreach ($t in $snap.Targets) {
                Write-Info2 ("target: type={0}; url={1}" -f ([string]$t.type), ([string]$t.url))
            }
        }
        if ($snap.OrpheusTargets.Count -eq 0) {
            Write-Warn3 '没有找到 orpheus 页面目标。'
        }
    } elseif ($snap.PortOpen) {
        Write-Warn3 ("/json 读取失败: {0}" -f $snap.Error)
    }

    $ncm = @(Get-NcmProcessList)
    if ($ncm.Count -eq 0) {
        Write-Warn3 '网易云当前未运行。'
    } else {
        $main = Get-NcmMainProcess
        if ($main) {
            Write-Info2 ("cloudmusic 主进程 PID={0}; PPID={1}; Cmd={2}" -f $main.ProcessId, $main.ParentProcessId, ([string]$main.CommandLine))
        }
        if ($ncm.Count -gt 1) {
            Write-Info2 ("另有 {0} 个 cloudmusic 子进程。" -f ($ncm.Count - 1))
        }
    }

    $bot = @(Get-BotProcessList)
    if ($bot.Count -eq 0) {
        Write-Warn3 'BiliNCM-Bot 当前未运行。'
    } else {
        foreach ($p in $bot) {
            Write-Info2 ("BiliNCM-Bot PID={0}" -f $p.Id)
        }
    }

    $ncmPath = Resolve-NcmExe -Preferred $NcmExe
    if ($ncmPath) {
        Write-Info2 ("网易云路径: {0}" -f $ncmPath)
    } else {
        Write-Warn3 '没有找到网易云安装路径。'
    }
}

function Wait-CdpHealth {
    param([int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $last = Get-CdpSnapshot -TimeoutSec 2
        if ($last.OrpheusTargets.Count -gt 0) { return $last }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return $last
}

# ----------------------------------------------------------------------
# 启动/重启网易云
# ----------------------------------------------------------------------
function Stop-NcmProcesses {
    $names = @('cloudmusic', 'cloudmusic_reporter', 'cloudmusic_util')
    $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $true }

    Write-Info2 ("正在关闭网易云进程: {0}" -f (($procs | ForEach-Object { $_.ProcessName + '#' + $_.Id }) -join ', '))
    foreach ($p in $procs) {
        try {
            if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() }
        } catch { }
    }

    Start-Sleep -Seconds 3

    $remaining = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    foreach ($p in $remaining) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $left = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Start-NcmWithCdp {
    param([string]$ExePath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = "--remote-debugging-port=$CdpPort"
    $psi.WorkingDirectory = Split-Path -Parent $ExePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false

    $p = [System.Diagnostics.Process]::Start($psi)
    Write-LauncherLog ("启动网易云: {0} --remote-debugging-port={1}; PID={2}" -f $ExePath, $CdpPort, $p.Id)
    return $p
}

function Ensure-Cdp {
    param([string]$Reason = '')

    $snap = Wait-CdpHealth -TimeoutSeconds 6
    if ($snap.OrpheusTargets.Count -gt 0) {
        Write-Ok2 '网易云 CDP 端口和目标页均正常。'
        return $true
    }

    # 端口已经打开但目标页还没出现，通常只是网易云页面还在加载。
    if ($snap.PortOpen -and $snap.JsonOk -and $snap.OrpheusTargets.Count -eq 0) {
        $snap = Wait-CdpHealth -TimeoutSeconds 10
        if ($snap.OrpheusTargets.Count -gt 0) {
            Write-Ok2 '网易云 CDP 端口和目标页均正常。'
            return $true
        }
    }

    $ncmProcs = @(Get-NcmProcessList)
    $exePath = Resolve-NcmExe -Preferred $NcmExe
    if (-not $exePath) {
        Write-Err2 '找不到网易云安装路径，无法开启 CDP。'
        Show-NcmDiagnostics
        return $false
    }

    if ($ncmProcs.Count -eq 0) {
        Write-Warn3 '网易云当前未运行。'
        if (-not (Read-YesNo "是否现在启动网易云并开启 $CdpPort 调试端口？" $true)) {
            Write-Warn3 '已取消启动网易云。'
            return $false
        }
    } else {
        Write-Warn3 "网易云正在运行，但 $CdpPort 调试端口/目标页不可用。"
        if (-not (Read-YesNo "需要重启网易云才能开启调试端口（会中断当前播放）。是否继续？" $false)) {
            Write-Warn3 '已取消重启网易云；CDP 仍不可用。'
            return $false
        }
        if (-not (Stop-NcmProcesses)) {
            Write-Err2 '网易云进程没有完全退出，无法安全重启。'
            Show-NcmDiagnostics
            return $false
        }
    }

    try {
        Start-NcmWithCdp -ExePath $exePath | Out-Null
    } catch {
        Write-Err2 ("启动网易云失败: {0}" -f $_.Exception.Message)
        Show-NcmDiagnostics
        return $false
    }

    $snap = Wait-CdpHealth -TimeoutSeconds $WaitSeconds
    if ($snap.OrpheusTargets.Count -gt 0) {
        Write-Ok2 ("网易云 CDP 已就绪（端口 {0}）。" -f $CdpPort)
        return $true
    }

    Write-Err2 ("网易云重新启动后仍没有可用的 CDP 目标（等待 {0} 秒）。" -f $WaitSeconds)
    Show-NcmDiagnostics
    return $false
}

# ----------------------------------------------------------------------
# 启动 bot / 日志捕获
# ----------------------------------------------------------------------
function Start-BotProcess {
    if ((Get-BotProcessList).Count -gt 0) { return $true }

    $exe = $null
    if (Test-Path -LiteralPath $Launcher) {
        $exe = $Launcher
    } elseif (Test-Path -LiteralPath $CurrentExe) {
        $exe = $CurrentExe
    } else {
        Write-Err2 '找不到 BiliNCM-Bot.exe。'
        return $false
    }

    Write-Info2 ("正在启动点歌机: {0}" -f $exe)
    try {
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
    } catch {
        Write-Err2 ("启动点歌机失败: {0}" -f $_.Exception.Message)
        return $false
    }

    $deadline = (Get-Date).AddSeconds(30)
    do {
        if ((Get-BotProcessList).Count -gt 0) {
            Write-Ok2 '点歌机进程已出现。'
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    Write-Err2 '启动命令已发出，但没有检测到 BiliNCM-Bot 进程。'
    return $false
}

function Wait-BotUi {
    param([int]$TimeoutSeconds = 25)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-TcpPort -Port 5555 -TimeoutMs 500) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-BotData {
    try {
        $text = Invoke-Utf8Http -Url 'http://localhost:5555/data' -TimeoutSec 2
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Wait-BotAutoPlayPaused {
    param([int]$TimeoutSeconds = 10)

    Write-Info2 '正在确认点歌机自动播放已暂停（由兼容层接管队列）...'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $last = Get-BotData
        if ($last) {
            $playingProp = $last.PSObject.Properties['playing']
            if ($playingProp -and $playingProp.Value -eq $false) {
                Write-LauncherLog '点歌机自动播放已暂停，兼容层接管队列。'
                return $true
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if (-not $last) {
        Write-Warn3 '无法读取点歌机 /data，未能确认自动播放是否暂停。'
        return $false
    }

    $currentProp = $last.PSObject.Properties['current']
    if ($currentProp -and $null -ne $currentProp.Value) {
        Write-Warn3 '点歌机自动播放仍开启且已有当前歌曲；为避免切歌，兼容层不会强制暂停。请勿点暂停，等当前歌曲自然结束后再处理。'
    } else {
        Write-Warn3 '点歌机自动播放尚未暂停；兼容层会继续尝试。请查看覆盖层告警，必要时手动暂停点歌机。'
    }
    return $false
}

function Start-BotLogCapture {
    if ($NoLogCapture) { return }
    if (-not (Test-Path -LiteralPath $CaptureScript)) {
        Write-Warn3 '没有找到 Capture-BotLogs.ps1，跳过日志捕获。'
        return
    }

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }

    $arg = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -OutFile "{2}"' -f $CaptureScript, $Root, $BotRuntimeLog
    try {
        Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden | Out-Null
        Write-LauncherLog ("已启动 bot 日志捕获: {0}" -f $BotRuntimeLog)
    } catch {
        Write-Warn3 ("启动 bot 日志捕获失败: {0}" -f $_.Exception.Message)
    }
}

function Start-CompanionProcess {
    if (-not (Test-Path -LiteralPath $CompanionScript)) {
        Write-Warn3 '没有找到 BiliNCM-Companion.ps1，点歌入队兼容层不会启动。'
        return
    }

    try {
        $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and
            $_.CommandLine -notmatch '-Command' -and
            $_.CommandLine -match '-File\s+.*BiliNCM-Companion\.ps1'
        })
        if ($existing.Count -gt 0) {
            Write-LauncherLog ("点歌兼容层已在运行: PID {0}" -f (($existing | ForEach-Object { $_.ProcessId }) -join ','))
            $fresh = $false
            if (Test-Path -LiteralPath $OverlayStateFile) {
                try {
                    $age = ((Get-Date) - (Get-Item -LiteralPath $OverlayStateFile).LastWriteTime).TotalSeconds
                    if ($age -le 15) { $fresh = $true }
                } catch { }
            }
            if (-not $fresh) {
                $young = $false
                foreach ($proc in $existing) {
                    try {
                        if ($proc.CreationDate -and ((Get-Date) - [datetime]$proc.CreationDate).TotalSeconds -lt 20) { $young = $true }
                    } catch { }
                }
                if (-not $young) {
                    Write-Warn3 '点歌兼容层进程存在，但 overlay 状态超过 15 秒没有更新；可能是旧版或已卡住。请先运行“关闭点歌机.cmd”再重新启动。'
                }
            }
            return
        }
    } catch { }

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }

    $arg = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Root "{1}"' -f $CompanionScript, $Root
    try {
        Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden | Out-Null
        Write-LauncherLog ("已启动点歌兼容层: {0}" -f $CompanionLog)
    } catch {
        Write-Warn3 ("启动点歌兼容层失败: {0}" -f $_.Exception.Message)
    }
}

function Start-OverlayProcess {
    if (-not (Test-Path -LiteralPath $OverlayScript)) {
        Write-Warn3 '没有找到 BiliNCM-Overlay.ps1，OBS 覆盖层不会启动。'
        return
    }

    try {
        $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and
            $_.CommandLine -notmatch '-Command' -and
            $_.CommandLine -match '-File\s+.*BiliNCM-Overlay\.ps1'
        })
        if ($existing.Count -gt 0) {
            Write-LauncherLog ("OBS 覆盖层已在运行: PID {0}" -f (($existing | ForEach-Object { $_.ProcessId }) -join ','))
            if (-not (Test-OverlayHealth)) {
                Write-Warn3 ("OBS 覆盖层进程存在，但 http://127.0.0.1:{0}/health 无响应；请查看 {1}。" -f $OverlayPort, $OverlayLog)
            }
            return
        }
    } catch { }

    if (Test-TcpPort -Port $OverlayPort -TimeoutMs 500) {
        Write-Warn3 ("端口 {0} 已被其他程序占用，OBS 覆盖层无法启动；请关闭占用该端口的程序。" -f $OverlayPort)
        return
    }

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }

    $arg = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -Port {2}' -f $OverlayScript, $Root, $OverlayPort
    try {
        Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden | Out-Null
        Write-LauncherLog ("已启动 OBS 覆盖层: {0}" -f $OverlayLog)
    } catch {
        Write-Warn3 ("启动 OBS 覆盖层失败: {0}" -f $_.Exception.Message)
        return
    }

    $deadline = (Get-Date).AddSeconds(5)
    do {
        if (Test-OverlayHealth) {
            Write-Ok2 ("OBS 覆盖层已启动: http://127.0.0.1:{0}/" -f $OverlayPort)
            return
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)

    Write-Warn3 ("OBS 覆盖层已启动，但 http://127.0.0.1:{0}/health 无响应；请查看 {1}。" -f $OverlayPort, $OverlayLog)
}

# ----------------------------------------------------------------------
# 彻底关闭 bot
# ----------------------------------------------------------------------
function Stop-BotProcesses {
    $bot = @(Get-BotProcessList)
    if ($bot.Count -eq 0) {
        Write-Info2 'BiliNCM-Bot 当前未运行。'
        return $true
    }

    Write-Info2 ("正在请求点歌机退出: {0}" -f (($bot | ForEach-Object { 'PID ' + $_.Id }) -join ', '))
    try {
        Invoke-WebRequest -Uri 'http://localhost:5555/api/exit' -Method POST -UseBasicParsing -TimeoutSec 3 | Out-Null
        Write-LauncherLog '已发送 /api/exit'
    } catch {
        Write-LauncherLog ("/api/exit 请求结束（连接被关闭通常表示 bot 正在退出）: {0}" -f $_.Exception.Message)
    }

    $deadline = (Get-Date).AddSeconds(10)
    do {
        if ((Get-BotProcessList).Count -eq 0) {
            Write-Ok2 '点歌机进程已退出。'
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    Write-Warn3 '点歌机没有在 10 秒内退出，执行强制结束。'
    foreach ($p in @(Get-BotProcessList)) {
        try {
            if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() }
        } catch { }
    }

    Start-Sleep -Seconds 2
    foreach ($p in @(Get-BotProcessList)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }

    $deadline = (Get-Date).AddSeconds(5)
    do {
        if ((Get-BotProcessList).Count -eq 0) {
            Write-Ok2 '点歌机进程已强制结束。'
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)

    Write-Err2 '点歌机进程仍未退出。'
    return $false
}

function Stop-CompanionProcesses {
    $targets = @()
    try {
        $targets = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -and
            ($_.CommandLine -match 'BiliNCM-Companion\.ps1' -or $_.CommandLine -match 'BiliNCM-Overlay\.ps1' -or $_.CommandLine -match 'Capture-BotLogs\.ps1')
        })
    } catch {
        Write-Warn3 ("枚举后台 PowerShell 失败: {0}" -f $_.Exception.Message)
        return
    }

    foreach ($target in $targets) {
        try {
            Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
            Write-LauncherLog ("已结束后台进程: PID={0}" -f $target.ProcessId)
        } catch { }
    }
}

# ----------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------
Write-Head 'BiliNCM-Bot CDP 启动包装器'
Write-Info2 ("安装目录: {0}" -f $Root)
Write-Info2 ("CDP 端口: {0}" -f $CdpPort)

$botProcs = @(Get-BotProcessList)

if ($StopBot) {
    Write-Head '关闭 BiliNCM-Bot'
    if (-not $ForceStop) {
        if (-not (Read-YesNo '确定彻底关闭点歌机吗？' $false)) {
            Write-Info2 '已取消关闭。'
            exit 0
        }
    }
    $botOk = Stop-BotProcesses
    Stop-CompanionProcesses
    if (-not $botOk) { exit 1 }
    Write-Ok2 '点歌机已彻底关闭；网易云音乐未关闭。'
    exit 0
}

if ($CheckOnly) {
    Show-NcmDiagnostics
    $snap = Get-CdpSnapshot -TimeoutSec 2
    if ($snap.OrpheusTargets.Count -gt 0) { exit 0 }
    exit 2
}

if ($botProcs.Count -gt 0) {
    Write-Warn3 '检测到点歌机已经在运行；不会重复启动，也不会结束它。'
    if ($DebugLogin) {
        Write-Err2 '调试登录需要先完全退出点歌机；本次没有执行登录检查。'
        exit 1
    }
    Start-BotLogCapture
    Start-CompanionProcess
    Start-OverlayProcess
    $null = Wait-BotAutoPlayPaused -TimeoutSeconds 10
    $ok = Ensure-Cdp -Reason 'bot-running'
    if ($ok) {
        Write-Ok2 'CDP 正常，现有 bot 可以继续使用。'
        exit 0
    }
    Write-Err2 'CDP 不可用；bot 仍在运行，但没有网易云控制能力。'
    exit 2
}

if (-not $SkipLoginCheck) {
    if (-not (Test-Path -LiteralPath $LoginScript)) {
        Write-Err2 '找不到 BiliLoginFix.ps1，无法验证登录。'
        exit 1
    }

    Write-Info2 '正在验证 B 站登录状态（不会启动 bot）...'
    $loginArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LoginScript, '-NoLaunch')
    if ($DebugLogin) { $loginArgs += '-DebugLogin' }
    & powershell.exe @loginArgs
    $loginRc = $LASTEXITCODE
    if ($loginRc -ne 0) {
        Write-Err2 ("登录检查未通过，退出码: {0}" -f $loginRc)
        exit 1
    }
    Write-Ok2 '登录检查完成。'
}

# 如果网易云完全没运行，先带调试端口启动一次。
# 这样 bot 启动时能通过进程拿到安装路径，进而执行它自己的
# RestartNCMWithDebugPort() 并启动切歌雷达；否则 bot 找不到
# 非标准安装路径时只会报错，连雷达都不会启动。
$ncmBeforeBot = @(Get-NcmProcessList)
if ($ncmBeforeBot.Count -eq 0) {
    $ncmExePath = Resolve-NcmExe -Preferred $NcmExe
    if ($ncmExePath) {
        Write-Warn3 '网易云当前未运行；先启动网易云（带调试端口），确保 bot 能识别路径并启动雷达。'
        try {
            Start-NcmWithCdp -ExePath $ncmExePath | Out-Null
        } catch {
            Write-Warn3 ("预启动网易云失败: {0}" -f $_.Exception.Message)
        }

        $ncmWaitDeadline = (Get-Date).AddSeconds(15)
        do {
            if ((Get-NcmProcessList).Count -gt 0) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $ncmWaitDeadline)

        if ((Get-NcmProcessList).Count -eq 0) {
            Write-Warn3 '网易云进程没有出现；bot 启动后仍会再次检查。'
        }
    } else {
        Write-Warn3 '网易云未运行，且没有找到安装路径；bot 启动后可能需要手动处理。'
    }
}

Start-CompanionProcess
Start-OverlayProcess
if (-not (Start-BotProcess)) { exit 1 }

Start-BotLogCapture
Start-CompanionProcess

if (-not (Wait-BotUi -TimeoutSeconds 25)) {
    $botNow = @(Get-BotProcessList)
    if ($botNow.Count -eq 0) {
        Write-Err2 '点歌机进程已经退出，启动失败。'
        exit 1
    }
    Write-Warn3 '没有检测到 5555 端口，bot 可能仍在启动中。'
}

$null = Wait-BotAutoPlayPaused -TimeoutSeconds 10

# bot 启动后自己可能会重启网易云；等它完成后再检查一次。
Start-Sleep -Seconds 5
$snap = Wait-CdpHealth -TimeoutSeconds 15
if ($snap.OrpheusTargets.Count -gt 0) {
    Write-Ok2 '点歌机已启动，CDP 已就绪。'
    exit 0
}

Write-Warn3 '点歌机已启动，但 CDP 端口/目标页仍未就绪。'
if (-not (Ensure-Cdp -Reason 'post-bot')) {
    Write-Err2 'CDP 未能恢复。bot 仍在运行，但网易云控制不可用。'
    exit 2
}

Write-Ok2 'CDP 已恢复；请保持网易云和 bot 运行。'
exit 0
