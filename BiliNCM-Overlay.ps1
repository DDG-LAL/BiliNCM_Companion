#requires -Version 5.1
<#
    BiliNCM overlay HTTP server
    ------------------------------------------------------------------
    Serves the OBS browser-source page, the live state JSON produced by
    BiliNCM-Companion.ps1, and the local skin / background settings page.

    - Listens on 127.0.0.1 only.
    - GET /                  -> BiliNCM-Overlay.html (OBS source only)
    - GET /settings          -> BiliNCM-Overlay-Settings.html
    - GET /state             -> overlay-state.json
    - GET /api/overlay-config-> current skin / background config
    - POST /api/overlay-config -> save config
    - POST /api/overlay-upload -> upload a PNG / JPEG background
    - GET /assets/<file>     -> uploaded background image
    - GET /health            -> {"ok":true}
    - GET /favicon.ico       -> 204

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
$SettingsFile = Join-Path $Root 'BiliNCM-Overlay-Settings.html'
$StateFile = Join-Path $Root 'overlay-state.json'
$ConfigFile = Join-Path $Root 'overlay-config.json'
$AssetsDir = Join-Path $Root 'overlay-assets'
$LogFile = Join-Path $Root 'overlay.log'

$MaxBodyBytes = 20MB
$MaxImageBytes = 12MB
$MaxImagePixels = 40000000
$MaxImageEdge = 3840
$AllowedSkins = @('default', 'neon', 'mist', 'sakura', 'pixel', 'lyric')
$AllowedFits = @('cover', 'contain-blur', 'stretch')
$AllowedOrigins = @(
    "http://127.0.0.1:$Port",
    "http://localhost:$Port"
)

function Write-OverlayLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Get-HttpReason {
    param([int]$Status)
    switch ($Status) {
        200 { return 'OK' }
        204 { return 'No Content' }
        400 { return 'Bad Request' }
        403 { return 'Forbidden' }
        404 { return 'Not Found' }
        405 { return 'Method Not Allowed' }
        411 { return 'Length Required' }
        413 { return 'Payload Too Large' }
        415 { return 'Unsupported Media Type' }
        500 { return 'Internal Server Error' }
        default { return 'OK' }
    }
}

function Send-OverlayBytes {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status,
        [string]$ContentType,
        [byte[]]$Bytes,
        [string]$ExtraHeaders = ''
    )
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $reason = Get-HttpReason -Status $Status
    $head = "HTTP/1.1 $Status $reason`r`n" +
            "Content-Type: $ContentType`r`n" +
            "Cache-Control: no-store, no-cache, must-revalidate`r`n" +
            "Pragma: no-cache`r`n" +
            "Access-Control-Allow-Origin: *`r`n" +
            "X-Content-Type-Options: nosniff`r`n" +
            "Referrer-Policy: no-referrer`r`n" +
            "Connection: close`r`n" +
            "Content-Length: $($Bytes.Length)`r`n" +
            $ExtraHeaders + "`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    try {
        $Stream.Write($headBytes, 0, $headBytes.Length)
        if ($Bytes.Length -gt 0) {
            $Stream.Write($Bytes, 0, $Bytes.Length)
        }
        $Stream.Flush()
    } catch { }
}

function Send-OverlayResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status,
        [string]$ContentType,
        [string]$Body,
        [string]$ExtraHeaders = ''
    )
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes([string]$Body)
    Send-OverlayBytes -Stream $Stream -Status $Status -ContentType $ContentType -Bytes $bodyBytes -ExtraHeaders $ExtraHeaders
}

function Send-OverlayJson {
    param(
        [System.IO.Stream]$Stream,
        [object]$Object,
        [int]$Status = 200
    )
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    Send-OverlayResponse -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body $json
}

function Send-OverlayError {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status,
        [string]$Code,
        [string]$Message = ''
    )
    $body = [pscustomobject]@{
        ok      = $false
        error   = $Code
        message = $Message
    }
    Send-OverlayJson -Stream $Stream -Object $body -Status $Status
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
# Overlay config
# ----------------------------------------------------------------------
function Get-DefaultConfig {
    return [pscustomobject]@{
        version    = 1
        skin       = 'default'
        background = [pscustomobject]@{
            file    = ''
            fit     = 'cover'
            opacity = 100
            scrim   = 35
            focusX  = 50
            focusY  = 50
        }
    }
}

function Clamp-IntValue {
    param(
        [object]$Value,
        [int]$Min,
        [int]$Max,
        [int]$Default
    )
    $n = 0
    if (-not [int]::TryParse([string]$Value, [ref]$n)) { $n = $Default }
    if ($n -lt $Min) { return $Min }
    if ($n -gt $Max) { return $Max }
    return $n
}

function Snap-FocusValue {
    param([object]$Value, [int]$Default = 50)
    $n = 0
    if (-not [int]::TryParse([string]$Value, [ref]$n)) { $n = $Default }
    if ($n -lt 25) { return 0 }
    if ($n -lt 75) { return 50 }
    return 100
}

function Normalize-Config {
    param([object]$Raw)
    $cfg = Get-DefaultConfig
    if ($null -eq $Raw) { return $cfg }

    $skin = [string]$Raw.skin
    if ($AllowedSkins -contains $skin) { $cfg.skin = $skin }

    $bg = $Raw.background
    if ($null -ne $bg) {
        $file = [string]$bg.file
        if ($file -match '^bg-[A-Za-z0-9-]+\.(png|jpg|jpeg)$') {
            $cfg.background.file = $file
        }
        $fit = [string]$bg.fit
        if ($AllowedFits -contains $fit) { $cfg.background.fit = $fit }
        $cfg.background.opacity = Clamp-IntValue -Value $bg.opacity -Min 0 -Max 100 -Default 100
        $cfg.background.scrim = Clamp-IntValue -Value $bg.scrim -Min 0 -Max 100 -Default 35
        $cfg.background.focusX = Snap-FocusValue -Value $bg.focusX -Default 50
        $cfg.background.focusY = Snap-FocusValue -Value $bg.focusY -Default 50
    }
    return $cfg
}

function Read-OverlayConfig {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        return Get-DefaultConfig
    }
    $text = ''
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $fs = [IO.File]::Open($ConfigFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
            } finally {
                $fs.Dispose()
            }
            break
        } catch {
            if ($attempt -eq 2) {
                Write-OverlayLog ("cannot read config: {0}" -f $_.Exception.Message) 'WARN'
                return Get-DefaultConfig
            }
            Start-Sleep -Milliseconds 60
        }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return Get-DefaultConfig }
    try {
        $raw = $text | ConvertFrom-Json
        return Normalize-Config -Raw $raw
    } catch {
        Write-OverlayLog ("invalid config json: {0}" -f $_.Exception.Message) 'WARN'
        return Get-DefaultConfig
    }
}

function Save-OverlayConfig {
    param([object]$Config)
    $json = $Config | ConvertTo-Json -Depth 6
    $tmp = $ConfigFile + '.tmp'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tmp, $json, $utf8)
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            Move-Item -LiteralPath $tmp -Destination $ConfigFile -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Get-AssetPath {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Name -notmatch '^bg-[A-Za-z0-9-]+\.(png|jpg|jpeg)$') { return $null }
    $base = [IO.Path]::GetFullPath($AssetsDir)
    $full = [IO.Path]::GetFullPath((Join-Path $base $Name))
    $prefix = $base.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

function Remove-OverlayAsset {
    param([string]$Name)
    $path = Get-AssetPath -Name $Name
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Write-OverlayLog ("removed old background: {0}" -f $Name)
        } catch {
            Write-OverlayLog ("cannot remove background {0}: {1}" -f $Name, $_.Exception.Message) 'WARN'
        }
    }
}

function Get-ConfigPayload {
    $cfg = Read-OverlayConfig
    $fileExists = $false
    if ($cfg.background.file) {
        $asset = Get-AssetPath -Name $cfg.background.file
        if ($asset -and (Test-Path -LiteralPath $asset)) { $fileExists = $true }
    }
    return [pscustomobject]@{
        ok         = $true
        config     = $cfg
        fileExists = $fileExists
    }
}

function Test-OriginAllowed {
    param([string]$Origin)
    if ([string]::IsNullOrWhiteSpace($Origin)) { return $true }
    return ($AllowedOrigins -contains $Origin)
}

# ----------------------------------------------------------------------
# Image upload / processing
# ----------------------------------------------------------------------
function Save-OverlayImage {
    param(
        [byte[]]$Bytes,
        [string]$ContentType
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return [pscustomobject]@{ ok = $false; error = 'empty_file' }
    }
    if ($Bytes.Length -gt $MaxImageBytes) {
        return [pscustomobject]@{ ok = $false; error = 'too_large' }
    }

    $ms = $null
    $img = $null
    $bmp = $null
    $g = $null
    $outMs = $null
    $encParams = $null

    try {
        $ms = New-Object System.IO.MemoryStream
        $ms.Write($Bytes, 0, $Bytes.Length)
        $ms.Position = 0
        $img = [System.Drawing.Image]::FromStream($ms)
        if ($null -eq $img -or $img.Width -lt 1 -or $img.Height -lt 1) {
            return [pscustomobject]@{ ok = $false; error = 'decode_failed' }
        }
        if (([int64]$img.Width * [int64]$img.Height) -gt $MaxImagePixels) {
            return [pscustomobject]@{ ok = $false; error = 'too_large_pixels' }
        }

        $orientation = 1
        try {
            $prop = $img.GetPropertyItem(0x0112)
            if ($prop -and $prop.Value -and $prop.Value.Length -ge 2) {
                $orientation = [BitConverter]::ToUInt16($prop.Value, 0)
            }
        } catch { }
        switch ($orientation) {
            2 { $img.RotateFlip([System.Drawing.RotateFlipType]::FlipX) }
            3 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
            4 { $img.RotateFlip([System.Drawing.RotateFlipType]::FlipY) }
            5 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipX) }
            6 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
            7 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipX) }
            8 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
        }

        $srcW = $img.Width
        $srcH = $img.Height
        $format = $img.RawFormat
        $isPng = ($format.Guid -eq [System.Drawing.Imaging.ImageFormat]::Png.Guid)
        $isJpeg = ($format.Guid -eq [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid)
        if (-not $isPng -and -not $isJpeg) {
            return [pscustomobject]@{ ok = $false; error = 'unsupported_type' }
        }

        $scale = 1.0
        $longEdge = [Math]::Max($srcW, $srcH)
        if ($longEdge -gt $MaxImageEdge) { $scale = $MaxImageEdge / $longEdge }
        $newW = [int][Math]::Max(1, [Math]::Round($srcW * $scale))
        $newH = [int][Math]::Max(1, [Math]::Round($srcH * $scale))

        if ($isPng) {
            $pixelFormat = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        } else {
            $pixelFormat = [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
        }

        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $newW, $newH, $pixelFormat
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        if ($isPng) {
            $g.Clear([System.Drawing.Color]::Transparent)
        } else {
            $g.Clear([System.Drawing.Color]::White)
        }
        $g.DrawImage($img, 0, 0, $newW, $newH)

        $outMs = New-Object System.IO.MemoryStream
        if ($isPng) {
            $bmp.Save($outMs, [System.Drawing.Imaging.ImageFormat]::Png)
            $ext = 'png'
            $mime = 'image/png'
        } else {
            $codec = $null
            foreach ($candidate in [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()) {
                if ($candidate.MimeType -eq 'image/jpeg') {
                    $codec = $candidate
                    break
                }
            }
            if ($null -eq $codec) {
                return [pscustomobject]@{ ok = $false; error = 'encoder_missing' }
            }
            $encParams = New-Object System.Drawing.Imaging.EncoderParameters -ArgumentList 1
            $qualityEncoder = [System.Drawing.Imaging.Encoder]::Quality
            $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter -ArgumentList @($qualityEncoder, [long]88)
            $bmp.Save($outMs, $codec, $encParams)
            $ext = 'jpg'
            $mime = 'image/jpeg'
        }

        $outBytes = $outMs.ToArray()
        if (-not (Test-Path -LiteralPath $AssetsDir)) {
            New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
        }
        $name = 'bg-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.' + $ext
        $dest = Join-Path $AssetsDir $name
        [IO.File]::WriteAllBytes($dest, $outBytes)
        return [pscustomobject]@{
            ok          = $true
            file        = $name
            width       = $newW
            height      = $newH
            bytes       = $outBytes.Length
            contentType = $mime
        }
    } catch {
        Write-OverlayLog ("image processing failed: {0}" -f $_.Exception.Message) 'ERROR'
        return [pscustomobject]@{ ok = $false; error = 'decode_failed' }
    } finally {
        if ($encParams) {
            try { $encParams.Param[0].Dispose() } catch { }
            try { $encParams.Dispose() } catch { }
        }
        if ($outMs) { try { $outMs.Dispose() } catch { } }
        if ($g) { try { $g.Dispose() } catch { } }
        if ($bmp) { try { $bmp.Dispose() } catch { } }
        if ($img) { try { $img.Dispose() } catch { } }
        if ($ms) { try { $ms.Dispose() } catch { } }
    }
}

# ----------------------------------------------------------------------
# Minimal HTTP request parser (headers + exact Content-Length body)
# ----------------------------------------------------------------------
function Read-HttpRequest {
    param([System.IO.Stream]$Stream)

    $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
    while ($headerBytes.Count -lt 32768) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { return $null }
        $headerBytes.Add([byte]$b)
        $n = $headerBytes.Count
        if ($n -ge 4 -and
            $headerBytes[$n - 4] -eq 13 -and
            $headerBytes[$n - 3] -eq 10 -and
            $headerBytes[$n - 2] -eq 13 -and
            $headerBytes[$n - 1] -eq 10) {
            break
        }
    }
    if ($headerBytes.Count -eq 0) { return $null }

    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    if ($lines.Count -lt 1) { return $null }

    $parts = [regex]::Split($lines[0], '\s+')
    if ($parts.Count -lt 2) { return $null }
    $method = ([string]$parts[0]).ToUpperInvariant()
    $rawPath = [string]$parts[1]

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf(':')
        if ($idx -le 0) { continue }
        $key = $line.Substring(0, $idx).Trim().ToLowerInvariant()
        $value = $line.Substring($idx + 1).Trim()
        $headers[$key] = $value
    }

    $contentLength = 0
    if ($headers.ContainsKey('content-length')) {
        [int]::TryParse([string]$headers['content-length'], [ref]$contentLength) | Out-Null
    }
    if ($contentLength -lt 0 -or $contentLength -gt $MaxBodyBytes) {
        return [pscustomobject]@{
            TooLarge = $true
            Method   = $method
            RawPath  = $rawPath
            Headers  = $headers
            Body     = [byte[]]@()
        }
    }

    if ($headers.ContainsKey('expect') -and ([string]$headers['expect'] -match '100-continue')) {
        $continueBytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
        try {
            $Stream.Write($continueBytes, 0, $continueBytes.Length)
            $Stream.Flush()
        } catch { }
    }

    $body = New-Object byte[] $contentLength
    $offset = 0
    while ($offset -lt $contentLength) {
        $read = $Stream.Read($body, $offset, $contentLength - $offset)
        if ($read -le 0) { break }
        $offset += $read
    }
    if ($offset -ne $contentLength) { return $null }

    return [pscustomobject]@{
        TooLarge = $false
        Method   = $method
        RawPath  = $rawPath
        Headers  = $headers
        Body     = $body
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
    if (-not (Test-Path -LiteralPath $SettingsFile)) {
        Write-OverlayLog ("settings page missing: {0}" -f $SettingsFile) 'WARN'
    }
    if (-not (Test-Path -LiteralPath $AssetsDir)) {
        try { New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null } catch { }
    }
    try { Add-Type -AssemblyName System.Drawing } catch {
        Write-OverlayLog ("System.Drawing unavailable; uploads will fail: {0}" -f $_.Exception.Message) 'WARN'
    }

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
    } catch {
        Write-OverlayLog ("cannot listen on 127.0.0.1:{0}: {1}" -f $Port, $_.Exception.Message) 'ERROR'
        exit 1
    }

    Write-OverlayLog ("overlay listening on http://127.0.0.1:{0}/" -f $Port)
    Write-OverlayLog ("settings page: http://127.0.0.1:{0}/settings" -f $Port)

    while ($true) {
        $client = $null
        $stream = $null
        try {
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 15000
            $client.SendTimeout = 15000
            $stream = $client.GetStream()

            $request = Read-HttpRequest -Stream $stream
            if ($null -eq $request) { continue }

            if ($request.TooLarge) {
                Send-OverlayError -Stream $stream -Status 413 -Code 'too_large' -Message 'request body too large'
                continue
            }

            $method = [string]$request.Method
            $path = ([string]$request.RawPath -split '\?')[0]
            try { $path = [Uri]::UnescapeDataString($path) } catch { }
            if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }

            $origin = ''
            if ($request.Headers.ContainsKey('origin')) {
                $origin = [string]$request.Headers['origin']
            }

            if ($method -eq 'OPTIONS') {
                if (-not (Test-OriginAllowed -Origin $origin)) {
                    Send-OverlayError -Stream $stream -Status 403 -Code 'origin_denied'
                    continue
                }
                $extra = "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
                         "Access-Control-Allow-Headers: Content-Type`r`n" +
                         "Access-Control-Max-Age: 600`r`n"
                Send-OverlayResponse -Stream $stream -Status 204 -ContentType 'text/plain; charset=utf-8' -Body '' -ExtraHeaders $extra
                continue
            }

            if ($path -eq '/state' -or $path -eq '/state.json') {
                Send-OverlayResponse -Stream $stream -Status 200 -ContentType 'application/json; charset=utf-8' -Body (Get-StateJson)
                continue
            }

            if ($path -eq '/' -or $path -eq '/index.html') {
                try {
                    $html = [IO.File]::ReadAllText($HtmlFile, [Text.Encoding]::UTF8)
                    Send-OverlayResponse -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body $html
                } catch {
                    Send-OverlayResponse -Stream $stream -Status 500 -ContentType 'text/plain; charset=utf-8' -Body 'overlay page read failed'
                }
                continue
            }

            if ($path -eq '/settings' -or $path -eq '/settings.html') {
                if (-not (Test-Path -LiteralPath $SettingsFile)) {
                    Send-OverlayResponse -Stream $stream -Status 404 -ContentType 'text/plain; charset=utf-8' -Body 'settings page not found'
                    continue
                }
                try {
                    $html = [IO.File]::ReadAllText($SettingsFile, [Text.Encoding]::UTF8)
                    Send-OverlayResponse -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body $html
                } catch {
                    Send-OverlayResponse -Stream $stream -Status 500 -ContentType 'text/plain; charset=utf-8' -Body 'settings page read failed'
                }
                continue
            }

            if ($path -eq '/api/overlay-config') {
                if ($method -eq 'GET') {
                    Send-OverlayJson -Stream $stream -Object (Get-ConfigPayload)
                    continue
                }
                if ($method -ne 'POST') {
                    Send-OverlayError -Stream $stream -Status 405 -Code 'method_not_allowed'
                    continue
                }
                if (-not (Test-OriginAllowed -Origin $origin)) {
                    Send-OverlayError -Stream $stream -Status 403 -Code 'origin_denied'
                    continue
                }
                if ($request.Body.Length -eq 0) {
                    Send-OverlayError -Stream $stream -Status 400 -Code 'empty_body'
                    continue
                }
                try {
                    $bodyText = [Text.Encoding]::UTF8.GetString($request.Body)
                    $rawConfig = $bodyText | ConvertFrom-Json
                } catch {
                    Send-OverlayError -Stream $stream -Status 400 -Code 'invalid_json'
                    continue
                }
                $newConfig = Normalize-Config -Raw $rawConfig
                $oldConfig = Read-OverlayConfig
                $oldFile = [string]$oldConfig.background.file
                try {
                    Save-OverlayConfig -Config $newConfig
                } catch {
                    Write-OverlayLog ("cannot save config: {0}" -f $_.Exception.Message) 'ERROR'
                    Send-OverlayError -Stream $stream -Status 500 -Code 'save_failed'
                    continue
                }
                $newFile = [string]$newConfig.background.file
                if ($oldFile -and $oldFile -ne $newFile) {
                    Remove-OverlayAsset -Name $oldFile
                }
                Write-OverlayLog ("config updated: skin={0}, fit={1}, bg={2}" -f $newConfig.skin, $newConfig.background.fit, $newFile)
                Send-OverlayJson -Stream $stream -Object (Get-ConfigPayload)
                continue
            }

            if ($path -eq '/api/overlay-upload') {
                if ($method -ne 'POST') {
                    Send-OverlayError -Stream $stream -Status 405 -Code 'method_not_allowed'
                    continue
                }
                if (-not (Test-OriginAllowed -Origin $origin)) {
                    Send-OverlayError -Stream $stream -Status 403 -Code 'origin_denied'
                    continue
                }
                $contentType = ''
                if ($request.Headers.ContainsKey('content-type')) {
                    $contentType = [string]$request.Headers['content-type']
                }
                $result = Save-OverlayImage -Bytes $request.Body -ContentType $contentType
                if (-not $result.ok) {
                    $status = 400
                    if ($result.error -eq 'too_large' -or $result.error -eq 'too_large_pixels') { $status = 413 }
                    elseif ($result.error -eq 'unsupported_type' -or $result.error -eq 'decode_failed') { $status = 415 }
                    elseif ($result.error -eq 'encoder_missing') { $status = 500 }
                    Send-OverlayError -Stream $stream -Status $status -Code $result.error
                    continue
                }

                $config = Read-OverlayConfig
                $oldFile = [string]$config.background.file
                $config.background.file = [string]$result.file
                try {
                    Save-OverlayConfig -Config $config
                } catch {
                    Remove-OverlayAsset -Name $result.file
                    Write-OverlayLog ("cannot save uploaded config: {0}" -f $_.Exception.Message) 'ERROR'
                    Send-OverlayError -Stream $stream -Status 500 -Code 'save_failed'
                    continue
                }
                if ($oldFile -and $oldFile -ne $result.file) {
                    Remove-OverlayAsset -Name $oldFile
                }
                Write-OverlayLog ("background uploaded: {0} ({1}x{2}, {3} bytes)" -f $result.file, $result.width, $result.height, $result.bytes)
                $payload = [pscustomobject]@{
                    ok         = $true
                    config     = $config
                    fileExists = $true
                    file       = $result.file
                    width      = $result.width
                    height     = $result.height
                    bytes      = $result.bytes
                }
                Send-OverlayJson -Stream $stream -Object $payload
                continue
            }

            if ($path.StartsWith('/assets/', [StringComparison]::OrdinalIgnoreCase)) {
                if ($method -ne 'GET') {
                    Send-OverlayError -Stream $stream -Status 405 -Code 'method_not_allowed'
                    continue
                }
                $name = $path.Substring('/assets/'.Length)
                $asset = Get-AssetPath -Name $name
                if (-not $asset -or -not (Test-Path -LiteralPath $asset)) {
                    Send-OverlayResponse -Stream $stream -Status 404 -ContentType 'text/plain; charset=utf-8' -Body 'not found'
                    continue
                }
                $ext = [IO.Path]::GetExtension($asset).ToLowerInvariant()
                if ($ext -eq '.png') { $mime = 'image/png' } else { $mime = 'image/jpeg' }
                try {
                    $bytes = [IO.File]::ReadAllBytes($asset)
                    Send-OverlayBytes -Stream $stream -Status 200 -ContentType $mime -Bytes $bytes
                } catch {
                    Send-OverlayResponse -Stream $stream -Status 500 -ContentType 'text/plain; charset=utf-8' -Body 'image read failed'
                }
                continue
            }

            if ($path -eq '/health') {
                $body = '{"ok":true,"port":' + $Port + '}'
                Send-OverlayResponse -Stream $stream -Status 200 -ContentType 'application/json; charset=utf-8' -Body $body
                continue
            }

            if ($path -eq '/favicon.ico') {
                Send-OverlayResponse -Stream $stream -Status 204 -ContentType 'image/x-icon' -Body ''
                continue
            }

            Send-OverlayResponse -Stream $stream -Status 404 -ContentType 'text/plain; charset=utf-8' -Body 'not found'
        } catch {
            # A browser closing a keep-alive probe is normal; only log
            # unexpected listener failures.
            if ($client -eq $null) {
                Write-OverlayLog ("accept failed: {0}" -f $_.Exception.Message) 'WARN'
                Start-Sleep -Milliseconds 500
            } else {
                Write-OverlayLog ("request failed: {0}" -f $_.Exception.Message) 'WARN'
            }
        } finally {
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
