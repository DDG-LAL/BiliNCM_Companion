#requires -Version 5.1
<#
    BiliNCM overlay HTTP server
    ------------------------------------------------------------------
    Serves the OBS browser-source page and the live state JSON produced
    by BiliNCM-Companion.ps1.

    - Listens on 127.0.0.1 only.
    - GET /        -> BiliNCM-Overlay.html
    - GET /state   -> overlay-state.json (written by the companion)
    - GET /health  -> {"ok":true}
    - GET /favicon.ico -> 204

    Started and stopped by BiliNCM-Launcher.ps1. No bot / current\ /
    NetEase Cloud Music files are touched.
#>

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [int]$Port = 5566
)

$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch { }

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$HtmlFile = Join-Path $Root 'BiliNCM-Overlay.html'
$StateFile = Join-Path $Root 'overlay-state.json'
$LogFile = Join-Path $Root 'overlay.log'

function Write-OverlayLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Send-OverlayResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status,
        [string]$ContentType,
        [string]$Body,
        [string]$ExtraHeaders = ''
    )
    $reason = switch ($Status) {
        200 { 'OK' }
        204 { 'No Content' }
        404 { 'Not Found' }
        default { 'OK' }
    }
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $head = "HTTP/1.1 $Status $reason`r`n" +
            "Content-Type: $ContentType`r`n" +
            "Cache-Control: no-store, no-cache, must-revalidate`r`n" +
            "Pragma: no-cache`r`n" +
            "Access-Control-Allow-Origin: *`r`n" +
            "Connection: close`r`n" +
            "Content-Length: $($bodyBytes.Length)`r`n" +
            $ExtraHeaders + "`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    try {
        $Stream.Write($headBytes, 0, $headBytes.Length)
        if ($bodyBytes.Length -gt 0) {
            $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
        }
        $Stream.Flush()
    } catch { }
}

function Get-StateJson {
    try {
        if (-not (Test-Path -LiteralPath $StateFile)) {
            return '{"ts":0,"bot":false,"ncm":false,"accepting":false,"current":null,"pending":[]}'
        }
        $text = ''
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                $fs = [IO.File]::Open($StateFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
                try {
                    $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                    $text = $reader.ReadToEnd()
                    $reader.Dispose()
                } finally {
                    $fs.Dispose()
                }
                break
            } catch {
                if ($attempt -eq 2) { throw }
                Start-Sleep -Milliseconds 60
            }
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            return '{"ts":0,"bot":false,"ncm":false,"accepting":false,"current":null,"pending":[]}'
        }
        $null = $text | ConvertFrom-Json
        return $text
    } catch {
        return '{"ts":0,"bot":false,"ncm":false,"accepting":false,"current":null,"pending":[]}'
    }
}

# ----------------------------------------------------------------------
# Single instance
# ----------------------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\BiliNCM-Overlay')
$haveMutex = $false
try {
    try { $haveMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
    if (-not $haveMutex) { exit 0 }

    try {
        if (Test-Path -LiteralPath $LogFile) {
            $item = Get-Item -LiteralPath $LogFile
            if ($item.Length -gt 1048576) {
                Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.1') -Force
            }
        }
    } catch { }

    if (-not (Test-Path -LiteralPath $HtmlFile)) {
        Write-OverlayLog ("overlay page missing: {0}" -f $HtmlFile) 'ERROR'
        exit 2
    }

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
    } catch {
        Write-OverlayLog ("cannot listen on 127.0.0.1:{0}: {1}" -f $Port, $_.Exception.Message) 'ERROR'
        exit 1
    }

    Write-OverlayLog ("overlay listening on http://127.0.0.1:{0}/" -f $Port)

    while ($true) {
        $client = $null
        $stream = $null
        $reader = $null
        try {
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 3000
            $client.SendTimeout = 3000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }

            for ($i = 0; $i -lt 100; $i++) {
                $header = $reader.ReadLine()
                if ($null -eq $header -or $header -eq '') { break }
            }

            $parts = $requestLine -split ' '
            $rawPath = if ($parts.Count -ge 2) { [string]$parts[1] } else { '/' }
            $path = ($rawPath -split '\?')[0]
            if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }

            if ($path -eq '/state' -or $path -eq '/state.json') {
                Send-OverlayResponse -Stream $stream -Status 200 -ContentType 'application/json; charset=utf-8' -Body (Get-StateJson)
            } elseif ($path -eq '/' -or $path -eq '/index.html') {
                try {
                    $html = [IO.File]::ReadAllText($HtmlFile, [Text.Encoding]::UTF8)
                    Send-OverlayResponse -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body $html
                } catch {
                    Send-OverlayResponse -Stream $stream -Status 500 -ContentType 'text/plain; charset=utf-8' -Body 'overlay page read failed'
                }
            } elseif ($path -eq '/health') {
                $body = '{"ok":true,"port":' + $Port + '}'
                Send-OverlayResponse -Stream $stream -Status 200 -ContentType 'application/json; charset=utf-8' -Body $body
            } elseif ($path -eq '/favicon.ico') {
                Send-OverlayResponse -Stream $stream -Status 204 -ContentType 'image/x-icon' -Body ''
            } else {
                Send-OverlayResponse -Stream $stream -Status 404 -ContentType 'text/plain; charset=utf-8' -Body 'not found'
            }
        } catch {
            # A browser closing a keep-alive probe is normal; only log
            # unexpected listener failures.
            if ($client -eq $null) {
                Write-OverlayLog ("accept failed: {0}" -f $_.Exception.Message) 'WARN'
                Start-Sleep -Milliseconds 500
            }
        } finally {
            try { if ($reader) { $reader.Dispose() } } catch { }
            try { if ($stream) { $stream.Dispose() } } catch { }
            try { if ($client) { $client.Close() } } catch { }
        }
    }
} finally {
    if ($haveMutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    try { $mutex.Dispose() } catch { }
}
