#requires -Version 5.1
<#
    BiliNCM-Bot 扫码登录修复启动器
    ------------------------------------------------------------------
    背景：
      B 站自 2026-08 起修改了网页扫码登录接口。扫码成功后，
      passport 轮询接口返回的 data.url 不再直接包含 SESSDATA，
      而是一张 crossDomain ticket 链接；真正的 Cookie 需要再请求
      该链接，从响应头 Set-Cookie 中获取。

      BiliNCM-Bot v1.0.1 仍按旧流程从 URL 查询串里取 Cookie，
      所以手机提示登录成功、电脑端却始终没有登录态。

    本脚本做的事情：
      1. 检查本机是否已有有效 Cookie（调用 B 站 nav 接口验证）；
      2. 有效则直接启动点歌机；
      3. 无效/过期则生成二维码（本地渲染，不经过第三方），
         扫码确认后用 ticket 换回真正的 Cookie；
      4. 写入 current\config.json，然后启动点歌机。

    文件位置（必须都在 BiliNCM-Bot-win-Portable 根目录）：
      BiliLoginFix.ps1   本脚本
      启动点歌机.cmd      双击入口
      调试登录.cmd        诊断入口（带 -DebugLogin）
      qrcode.js          本地二维码库（qrcode-generator, MIT）
      BiliNCM-Bot.exe    原启动器（不修改）
      current\           原程序目录（config.json 由本脚本写入）

    仅与 B 站官方 passport / api 域名通信，Cookie 只保存在本机。
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$NoLaunch,
    [switch]$TestQr,
    [switch]$DebugLogin
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http | Out-Null

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::InputEncoding  = [Text.Encoding]::UTF8
} catch { }

$Root       = $PSScriptRoot
$ConfigPath = Join-Path $Root 'current\config.json'
$Launcher   = Join-Path $Root 'BiliNCM-Bot.exe'
$CurrentExe = Join-Path $Root 'current\BiliNCM-Bot.exe'
$QrHtmlPath = Join-Path $Root '_qrcode.html'
$QrLibPath  = Join-Path $Root 'qrcode.js'

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

$PassHeaders = @{
    'User-Agent'      = $UA
    'Referer'         = 'https://passport.bilibili.com/'
    'Accept'          = 'application/json, text/plain, */*'
    'Accept-Language' = 'zh-CN,zh;q=0.9'
}

$ApiHeaders = @{
    'User-Agent'      = $UA
    'Referer'         = 'https://www.bilibili.com/'
    'Accept'          = 'application/json, text/plain, */*'
    'Accept-Language' = 'zh-CN,zh;q=0.9'
}

# ----------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("  " + ('-' * 62)) -ForegroundColor DarkGray
}
function Write-Info([string]$Text)  { Write-Host ("  " + $Text) -ForegroundColor Gray }
function Write-Ok([string]$Text)    { Write-Host ("  " + $Text) -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host ("  " + $Text) -ForegroundColor Yellow }
function Write-Err([string]$Text)   { Write-Host ("  " + $Text) -ForegroundColor Red }

# ----------------------------------------------------------------------
# 进程检查
# ----------------------------------------------------------------------
function Get-BotProcessCount {
    return @(Get-Process -Name 'BiliNCM-Bot' -ErrorAction SilentlyContinue).Count
}

function Wait-BotClosed {
    $tries = 0
    while ((Get-BotProcessCount) -gt 0) {
        $tries++
        if ($tries -gt 30) {
            throw '点歌机仍在运行。请手动结束 BiliNCM-Bot.exe 后重新运行本脚本。'
        }
        Write-Warn2 '检测到点歌机正在运行。'
        Write-Info '请先从托盘右键退出，或到任务管理器结束 BiliNCM-Bot.exe。'
        [void](Read-Host '完全退出后按回车继续')
        Start-Sleep -Milliseconds 600
    }
}

function Start-BiliBot {
    $exe = $null
    if (Test-Path -LiteralPath $Launcher) {
        $exe = $Launcher
    } elseif (Test-Path -LiteralPath $CurrentExe) {
        $exe = $CurrentExe
    } else {
        throw "找不到 BiliNCM-Bot.exe，请确认脚本放在安装目录根目录：$Root"
    }

    Write-Info "正在启动: $exe"
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
    Start-Sleep -Seconds 3

    if ((Get-BotProcessCount) -gt 0) {
        Write-Ok '点歌机已启动，控制台会自动在浏览器中打开。'
    } else {
        Write-Warn2 '启动命令已发出，但暂未检测到点歌机进程，请留意是否有错误提示窗口。'
    }
}

# ----------------------------------------------------------------------
# Cookie / 查询串
# ----------------------------------------------------------------------
function ConvertFrom-QueryString {
    param([string]$Url)

    $dict = @{}
    if ([string]::IsNullOrWhiteSpace($Url)) { return $dict }

    try { $uri = [Uri]$Url } catch { return $dict }
    $query = $uri.Query
    if ([string]::IsNullOrEmpty($query)) { return $dict }

    foreach ($pair in $query.TrimStart('?').Split('&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $idx = $pair.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $pair.Substring(0, $idx)
        $val = $pair.Substring($idx + 1)
        if ($key) { $dict[$key] = $val }
    }
    return $dict
}

function ConvertFrom-CookieString {
    param([string]$Cookie)

    $dict = @{}
    foreach ($part in ($Cookie -split ';')) {
        $part = $part.Trim()
        if (-not $part) { continue }
        $idx = $part.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $part.Substring(0, $idx).Trim()
        $val = $part.Substring($idx + 1).Trim()
        if ($key) { $dict[$key] = $val }
    }
    return $dict
}

function Get-CookieString {
    param([hashtable]$Cookies)

    $order = @('SESSDATA', 'bili_jct', 'DedeUserID', 'DedeUserID__ckMd5', 'buvid3', 'buvid4', 'ac_time_value')
    $ignore = @('gourl', 'first_domain', 'ticket', 'navhide', 'callback', 'from', 'qrcode_key', 'source')
    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($key in $order) {
        if ($Cookies.ContainsKey($key) -and $Cookies[$key]) {
            $parts.Add(('{0}={1}' -f $key, $Cookies[$key]))
        }
    }
    foreach ($key in $Cookies.Keys) {
        if (($order -notcontains $key) -and ($ignore -notcontains $key) -and $Cookies[$key]) {
            $parts.Add(('{0}={1}' -f $key, $Cookies[$key]))
        }
    }
    # 与 known-good 脚本保持一致：用分号直接连接，不在分号后加空格。
    # 个别服务端按 ";" 切分后不会 trim，带空格的键名会导致 DedeUserID 等被忽略。
    return ($parts -join ';')
}

# ----------------------------------------------------------------------
# B 站接口
# ----------------------------------------------------------------------
function Test-BiliLogin {
    param(
        [string]$Cookie,
        [string]$NavUrl = 'https://api.bilibili.com/x/web-interface/nav'
    )

    if ([string]::IsNullOrWhiteSpace($Cookie)) {
        return [pscustomobject]@{ Status = 'Invalid'; Uid = 0; Code = -101; Message = '账号未登录' }
    }

    # 注意：Windows PowerShell 5.1 的 Invoke-RestMethod 会丢弃 -Headers 里的 Cookie。
    # 必须用 HttpClient 手动发 Cookie 头，否则任何有效 SESSDATA 都会被误判成 -101。
    $handler = New-Object -TypeName System.Net.Http.HttpClientHandler
    $handler.UseCookies = $false
    try {
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    } catch { }
    $client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList $handler
    $client.Timeout = [TimeSpan]::FromSeconds(15)

    $request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), $NavUrl
    try {
        [void]$request.Headers.TryAddWithoutValidation('User-Agent', $UA)
        [void]$request.Headers.TryAddWithoutValidation('Referer', 'https://www.bilibili.com/')
        [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json, text/plain, */*')
        [void]$request.Headers.TryAddWithoutValidation('Accept-Language', 'zh-CN,zh;q=0.9')
        [void]$request.Headers.TryAddWithoutValidation('Cookie', $Cookie)

        $resp = $client.SendAsync($request).Result
        $body = $resp.Content.ReadAsStringAsync().Result
        $r = $body | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ Status = 'NetworkError'; Uid = 0; Code = 0; Message = $_.Exception.Message }
    } finally {
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
    }

    $code = -999
    try { $code = [int]$r.code } catch { }
    $isLogin = $false
    try { $isLogin = [bool]$r.data.isLogin } catch { }
    $uid = 0
    try { $uid = [long]$r.data.mid } catch { }
    $msg = ''
    try { $msg = [string]$r.message } catch { }

    if ($code -eq 0 -and $isLogin) {
        return [pscustomobject]@{ Status = 'Valid'; Uid = $uid; Code = 0; Message = 'OK' }
    }
    if ($code -eq 0 -and -not $isLogin) {
        return [pscustomobject]@{ Status = 'Invalid'; Uid = 0; Code = 0; Message = 'isLogin=false' }
    }
    if ($code -eq -101) {
        return [pscustomobject]@{ Status = 'Invalid'; Uid = 0; Code = $code; Message = '账号未登录' }
    }
    return [pscustomobject]@{ Status = 'Other'; Uid = $uid; Code = $code; Message = $msg }
}

function Add-BuvidCookies {
    param([hashtable]$Cookies)

    if ($Cookies.ContainsKey('buvid3') -and $Cookies['buvid3']) { return }

    try {
        $r = Invoke-RestMethod -Uri 'https://api.bilibili.com/x/frontend/finger/spi' -Headers $ApiHeaders -Method Get -TimeoutSec 10
        if ([int]$r.code -eq 0) {
            if ($r.data.b_3) { $Cookies['buvid3'] = [string]$r.data.b_3 }
            if ($r.data.b_4) { $Cookies['buvid4'] = [string]$r.data.b_4 }
        }
    } catch {
        # 拿不到就用点歌机自带的兜底 buvid
    }
}

function New-BiliQr {
    param([Microsoft.PowerShell.Commands.WebRequestSession]$WebSession)

    $uri = 'https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source=main-fe-header'
    if ($WebSession) {
        $webResp = Invoke-WebRequest -Uri $uri -Headers $PassHeaders -Method Get -WebSession $WebSession -UseBasicParsing -TimeoutSec 20
        $r = $webResp.Content | ConvertFrom-Json
    } else {
        $r = Invoke-RestMethod -Uri $uri -Headers $PassHeaders -Method Get -TimeoutSec 20
    }
    if ([int]$r.code -ne 0) {
        throw "获取二维码失败: code=$($r.code) $($r.message)"
    }
    if (-not $r.data.url -or -not $r.data.qrcode_key) {
        throw '获取二维码失败：接口返回数据不完整。'
    }
    return [pscustomobject]@{
        Url = [string]$r.data.url
        Key = [string]$r.data.qrcode_key
    }
}

function Wait-BiliQr {
    param(
        [string]$Key,
        [int]$TimeoutSeconds = 175,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    if (-not $WebSession) {
        $WebSession = New-Object -TypeName Microsoft.PowerShell.Commands.WebRequestSession
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = ''
    $failCount = 0

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2

        try {
            $uri = 'https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key={0}&source=main-fe-header' -f [Uri]::EscapeDataString($Key)
            $webResp = Invoke-WebRequest -Uri $uri -Headers $PassHeaders -Method Get -WebSession $WebSession -UseBasicParsing -TimeoutSec 15
            $r = $webResp.Content | ConvertFrom-Json
            $failCount = 0
        } catch {
            $failCount++
            if ($failCount -ge 5) {
                throw "轮询登录状态失败: $($_.Exception.Message)"
            }
            continue
        }

        $code = -1
        try { $code = [int]$r.data.code } catch { }

        switch ($code) {
            86101 {
                if ($last -ne 'wait') { Write-Info '等待扫码...'; $last = 'wait' }
            }
            86090 {
                if ($last -ne 'confirm') { Write-Ok '已扫码，请在手机上点击「确认登录」...'; $last = 'confirm' }
            }
            86038 {
                return [pscustomobject]@{ Status = 'Expired' }
            }
            0 {
                $pollCookies = @{}
                try {
                    foreach ($ck in $WebSession.Cookies.GetCookies([Uri]$uri)) {
                        if ($ck.Name -and $ck.Value) { $pollCookies[$ck.Name] = [string]$ck.Value }
                    }
                } catch { }

                # 2026-08 起扫码成功后 qrcode_key 会立即失效，不能再轮询第二次。
                # 必须在第一次 code=0 的响应里立刻取 data.url 去换 Cookie。
                $finalUrl = [string]$r.data.url
                $refreshToken = [string]$r.data.refresh_token
                if ($DebugLogin) {
                    $finalHost = '(无)'
                    if ($finalUrl) { try { $finalHost = ([Uri]$finalUrl).Host } catch { } }
                    Write-Info ("[debug] 首次成功轮询返回 URL 主机: {0}" -f $finalHost)
                }

                return [pscustomobject]@{
                    Status       = 'Success'
                    Url          = $finalUrl
                    RefreshToken = $refreshToken
                    Cookies      = $pollCookies
                }
            }
            default {
                if ($last -ne "code$code") {
                    Write-Warn2 "登录状态返回未知 code=$code"
                    $last = "code$code"
                }
            }
        }
    }

    return [pscustomobject]@{ Status = 'Timeout' }
}

function Test-BilibiliApiCookie {
    param(
        [string]$Domain,
        [string]$RequestHost
    )

    if ($Domain) {
        $d = $Domain.Trim().TrimStart('.').ToLowerInvariant()
        return ($d -eq 'bilibili.com' -or $d.EndsWith('.bilibili.com'))
    }

    # 没有 Domain 的 host-only Cookie，只对设置它的主机有效
    $h = ''
    if ($RequestHost) { $h = $RequestHost.Trim().ToLowerInvariant() }
    return ($h -eq 'api.bilibili.com' -or $h -eq 'bilibili.com')
}

function New-BiliCookieJar {
    param([Microsoft.PowerShell.Commands.WebRequestSession]$WebSession)

    $jar = New-Object -TypeName System.Net.CookieContainer

    # 把二维码生成/轮询阶段的 Cookie 带进换票请求，尽量保持同一个会话
    if ($WebSession) {
        foreach ($target in @('https://passport.bilibili.com/', 'https://www.bilibili.com/')) {
            try {
                foreach ($ck in $WebSession.Cookies.GetCookies([Uri]$target)) {
                    try { $jar.Add([Uri]$target, $ck) } catch { }
                }
            } catch { }
        }
    }
    return $jar
}

function Get-CrossDomainCookies {
    param(
        [string]$Url,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [System.Net.CookieContainer]$CookieJar
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [pscustomobject]@{
            Cookies       = @{}
            CandidateSets = (New-Object System.Collections.ArrayList)
            NewApiSess    = $false
        }
    }

    # 多个跨域地址共用同一个 CookieContainer，等价于 known-good 脚本里的
    # 同一个 requests.Session。前一跳设置的 sid/default_sites 等 Cookie
    # 必须能带到下一跳，否则主站换票可能拿不到 SESSDATA。
    $cookieJar = $CookieJar
    if (-not $cookieJar) {
        $cookieJar = New-BiliCookieJar -WebSession $WebSession
    }

    $handler = New-Object -TypeName System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $true
    $handler.CookieContainer = $cookieJar
    try {
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    } catch { }

    $client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList $handler
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UA)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Referer', 'https://passport.bilibili.com/')
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept-Language', 'zh-CN,zh;q=0.9')

    $hopCandidates = New-Object System.Collections.ArrayList
    $allHops = @{}
    $apiFallback = @{}
    $apiAuthoritative = @{}
    $ssoUrls = New-Object System.Collections.ArrayList
    $seenSso = @{}
    $queue = New-Object System.Collections.Queue
    [void]$queue.Enqueue($Url)
    $seenQueue = @{}
    $seenQueue[$Url] = $true
    $requestCount = 0
    $maxRequests = 14

    try {
        while ($queue.Count -gt 0 -and $requestCount -lt $maxRequests) {
            $chainUrl = [string]$queue.Dequeue()
            $isMainChain = ($chainUrl -eq $Url)
            if ($isMainChain) { $chainLabel = '主链' } else { $chainLabel = 'SSO' }
            $current = $chainUrl

            for ($hop = 0; $hop -lt 6 -and $requestCount -lt $maxRequests; $hop++) {
                $requestCount++
                $requestUri = [Uri]$current

                $resp = $null
                try {
                    $resp = $client.GetAsync($current).Result
                } catch {
                    $errMsg = [string]$_.Exception.Message
                    $errMsg = $errMsg -replace 'ticket=[^&\s]+', 'ticket=***'
                    if ($DebugLogin) { Write-Info ("[debug] 请求失败: {0}" -f $errMsg) }
                    break
                }
                if (-not $resp) { break }

                try {
                    $status = [int]$resp.StatusCode
                    $location = $null
                    try { $location = $resp.Headers.Location } catch { }

                    $locHost = '(无)'
                    if ($location) {
                        try {
                            if ($location.IsAbsoluteUri) {
                                $locHost = $location.Host + $location.AbsolutePath
                            } else {
                                $absLoc = [Uri]::new($requestUri, $location)
                                $locHost = $absLoc.Host + $absLoc.AbsolutePath
                            }
                        } catch { }
                    }
                    if ($DebugLogin) {
                        $reqDisplay = $requestUri.Host + $requestUri.AbsolutePath
                        Write-Info ("[debug] 请求 {0}（{1} 第 {2} 跳）: HTTP {3} {4} -> {5}" -f $requestCount, $chainLabel, ($hop + 1), $status, $reqDisplay, $locHost)
                    }

                    # 读取正文，用于发现页面里的 SSO 跳转。
                    # 只读取文本类内容，避免把二进制页面当字符串处理。
                    $body = ''
                    $mediaType = ''
                    try { $mediaType = [string]$resp.Content.Headers.ContentType.MediaType } catch { }
                    if (-not $mediaType -or $mediaType -match '(?i)^(text/|application/json|application/javascript|text/javascript)') {
                        try { $body = $resp.Content.ReadAsStringAsync().Result } catch { }
                    }
                    if ($DebugLogin -and $body -and $status -eq 200) {
                        $pageTitle = ''
                        $titleMatch = [regex]::Match($body, '(?is)<title[^>]*>(.*?)</title>')
                        if ($titleMatch.Success) {
                            $pageTitle = ($titleMatch.Groups[1].Value -replace '\s+', ' ').Trim()
                            if ($pageTitle.Length -gt 120) { $pageTitle = $pageTitle.Substring(0, 120) + '...' }
                        }
                        $ssoCount = ([regex]::Matches($body, '(?i)sso')).Count
                        Write-Info ("[debug]   页面: {0} 字符，标题: {1}，sso 出现次数: {2}" -f $body.Length, $pageTitle, $ssoCount)
                    }

                    $thisHopAll = @{}
                    $thisHopApi = @{}
                    $values = $null

                    if ($resp.Headers.TryGetValues('Set-Cookie', [ref]$values)) {
                        foreach ($raw in $values) {
                            $parts = @($raw -split ';')
                            $pair = $parts[0].Trim()
                            if (-not $pair) { continue }

                            $idx = $pair.IndexOf('=')
                            if ($idx -lt 1) { continue }

                            $name = $pair.Substring(0, $idx).Trim()
                            $value = $pair.Substring($idx + 1).Trim()
                            if (-not $name -or -not $value) { continue }

                            $domain = ''
                            for ($i = 1; $i -lt $parts.Count; $i++) {
                                $attr = $parts[$i].Trim()
                                if ($attr -match '^(?i)domain=(.+)$') {
                                    $domain = $Matches[1].Trim()
                                    break
                                }
                            }

                            $thisHopAll[$name] = $value
                            $allHops[$name] = $value

                            $keep = Test-BilibiliApiCookie -Domain $domain -RequestHost $requestUri.Host
                            if ($DebugLogin) {
                                $domainText = if ($domain) { $domain } else { '(host-only)' }
                                $keepText = if ($keep) { '保留' } else { '跳过' }
                                Write-Info ("[debug]   Set-Cookie: {0}  domain={1}  {2}" -f $name, $domainText, $keepText)
                            }

                            if ($keep) { $thisHopApi[$name] = $value }
                        }
                    }

                    if ($thisHopAll.Count -gt 0) {
                        [void]$hopCandidates.Add([pscustomobject]@{
                            Source  = ("{0} 请求 {1} 第 {2} 跳（{3}）" -f $chainLabel, $requestCount, ($hop + 1), $requestUri.Host)
                            Cookies = $thisHopAll
                        })
                    }

                    foreach ($key in $thisHopApi.Keys) {
                        if (-not $apiFallback.ContainsKey($key)) { $apiFallback[$key] = $thisHopApi[$key] }
                    }
                    if ($thisHopApi.ContainsKey('SESSDATA') -and $thisHopApi['SESSDATA']) {
                        # 与 known-good 脚本一致：同名 Cookie 以最后出现者为准
                        $apiAuthoritative = $thisHopApi.Clone()
                    }

                    # B 站换票链路有时不会在 302 头里直接给主站 Cookie，
                    # 而是把真正的 SSO 跳转放在最终页面正文里。known-good 脚本
                    # 会扫描正文并访问带 sso 的链接；这里做同样的事。
                    if ($body) {
                        $text = $body
                        $text = $text -replace '\\u0026', '&'
                        $text = $text -replace '\\/', '/'
                        $text = $text -replace '&amp;', '&'
                        $text = $text -replace '&quot;', '"'
                        $text = $text -replace '&#39;', "'"

                        $urlMatches = [regex]::Matches($text, '(?i)https?://[^"''\s<>\\]+')
                        foreach ($m in $urlMatches) {
                            $u = $m.Value.TrimEnd([char[]]@(')', ',', ';', '.', ']'))
                            if ($u -notmatch '(?i)sso') { continue }
                            if ($u -notmatch '(?i)passport|login|ticket=') { continue }
                            if ($u -notmatch '(?i)bilibili|biligame|huasheng') { continue }
                            if ($seenSso.ContainsKey($u)) { continue }
                            $seenSso[$u] = $true
                            [void]$ssoUrls.Add($u)
                            if (-not $seenQueue.ContainsKey($u)) {
                                $seenQueue[$u] = $true
                                [void]$queue.Enqueue($u)
                                if ($DebugLogin) {
                                    $ssoHost = '(未知)'
                                    try { $ssoHost = ([Uri]$u).Host } catch { }
                                    Write-Info ("[debug] 发现 SSO 跳转: {0}" -f $ssoHost)
                                }
                            }
                        }

                        $relMatches = [regex]::Matches($text, '(?i)["''](/[^"'']*sso[^"'']*)["'']')
                        foreach ($rm in $relMatches) {
                            $rel = $rm.Groups[1].Value
                            if ($rel -notmatch '(?i)passport|login|ticket=') { continue }
                            $u = ''
                            try { $u = (New-Object System.Uri -ArgumentList @($requestUri, $rel)).AbsoluteUri } catch { continue }
                            if (-not $u -or $seenSso.ContainsKey($u)) { continue }
                            $seenSso[$u] = $true
                            [void]$ssoUrls.Add($u)
                            if (-not $seenQueue.ContainsKey($u)) {
                                $seenQueue[$u] = $true
                                [void]$queue.Enqueue($u)
                                if ($DebugLogin) {
                                    $ssoHost = '(未知)'
                                    try { $ssoHost = ([Uri]$u).Host } catch { }
                                    Write-Info ("[debug] 发现 SSO 跳转: {0}" -f $ssoHost)
                                }
                            }
                        }
                    }

                    if ($location -and $status -ge 300 -and $status -lt 400) {
                        try {
                            if (-not $location.IsAbsoluteUri) {
                                $location = New-Object -TypeName System.Uri -ArgumentList @($requestUri, $location)
                            }
                            $current = $location.AbsoluteUri
                        } catch { break }
                    } else {
                        break
                    }
                } finally {
                    if ($resp) { $resp.Dispose() }
                }
            }
        }
    } finally {
        $client.Dispose()
    }

    # 域过滤后的合并集合（优先使用最后一次能用于 api.bilibili.com 的 Cookie）
    $apiMerged = @{}
    foreach ($key in $apiAuthoritative.Keys) { $apiMerged[$key] = $apiAuthoritative[$key] }
    foreach ($key in $apiFallback.Keys) {
        if (-not $apiMerged.ContainsKey($key)) { $apiMerged[$key] = $apiFallback[$key] }
    }
    try {
        foreach ($ck in $cookieJar.GetCookies([Uri]'https://api.bilibili.com/')) {
            if ($ck.Name -and $ck.Value -and -not $apiMerged.ContainsKey($ck.Name)) {
                $apiMerged[$ck.Name] = [string]$ck.Value
            }
        }
    } catch { }

    $jarOnly = @{}
    try {
        foreach ($ck in $cookieJar.GetCookies([Uri]'https://api.bilibili.com/')) {
            if ($ck.Name -and $ck.Value) { $jarOnly[$ck.Name] = [string]$ck.Value }
        }
    } catch { }

    # 候选顺序：域过滤合并 → CookieContainer → 所有请求合并 → 每一跳原始集合。
    # 这样真正的 .bilibili.com SESSDATA 会优先验证，不会被游戏域的同名 Cookie 拖慢。
    $candidates = New-Object System.Collections.ArrayList
    if ($apiMerged.ContainsKey('SESSDATA') -and $apiMerged['SESSDATA']) {
        [void]$candidates.Add([pscustomobject]@{
            Source  = 'api.bilibili.com 域过滤'
            Cookies = $apiMerged
        })
    }
    if ($jarOnly.ContainsKey('SESSDATA') -and $jarOnly['SESSDATA']) {
        [void]$candidates.Add([pscustomobject]@{
            Source  = 'CookieContainer'
            Cookies = $jarOnly
        })
    }
    if ($allHops.ContainsKey('SESSDATA') -and $allHops['SESSDATA']) {
        [void]$candidates.Add([pscustomobject]@{
            Source  = '所有请求合并（后写优先）'
            Cookies = $allHops
        })
    }
    foreach ($c in $hopCandidates) {
        if ($c.Cookies.ContainsKey('SESSDATA') -and $c.Cookies['SESSDATA']) {
            [void]$candidates.Add($c)
        }
    }

    $result = $apiMerged
    if (-not $result.ContainsKey('SESSDATA') -and $allHops.ContainsKey('SESSDATA')) {
        $result = $allHops
    }

    if ($DebugLogin) {
        Write-Info ("[debug] 共请求 {0} 个地址，发现 {1} 个 SSO 跳转。" -f $requestCount, $ssoUrls.Count)
        if ($result.Count -gt 0) {
            Write-Info ("[debug] 合并结果 Cookie: {0}" -f (($result.Keys | Sort-Object) -join ', '))
        } else {
            Write-Info '[debug] 合并结果没有 Cookie。'
        }
        $i = 0
        foreach ($c in $candidates) {
            $i++
            Write-Info ("[debug] 候选 {0}: {1}，Cookie: {2}" -f $i, $c.Source, (($c.Cookies.Keys | Sort-Object) -join ', '))
        }
    }

    $newApiSess = [bool]($apiAuthoritative.ContainsKey('SESSDATA') -and $apiAuthoritative['SESSDATA'])
    return [pscustomobject]@{
        Cookies       = $result
        CandidateSets = $candidates
        NewApiSess    = $newApiSess
    }
}

function Resolve-BiliLoginCookies {
    param(
        [string]$SuccessUrl,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    $empty = [pscustomobject]@{
        Cookies       = @{}
        CandidateSets = (New-Object System.Collections.ArrayList)
        NewApiSess    = $false
    }
    if ([string]::IsNullOrWhiteSpace($SuccessUrl)) { return $empty }

    # 旧流程：data.url 里直接带 SESSDATA 等 Cookie 参数
    if ($SuccessUrl -match 'SESSDATA=') {
        $dict = ConvertFrom-QueryString -Url $SuccessUrl
        $oldCandidates = New-Object System.Collections.ArrayList
        [void]$oldCandidates.Add([pscustomobject]@{ Source = '旧版 URL'; Cookies = $dict })
        return [pscustomobject]@{
            Cookies       = $dict
            CandidateSets = $oldCandidates
            NewApiSess    = $true
        }
    }

    # 新流程：data.url 是 crossDomain?ticket=...，需要再请求一次换 Cookie
    $query = ConvertFrom-QueryString -Url $SuccessUrl
    $ticket = $query['ticket']
    if (-not $ticket) { return $empty }

    $gourl = 'https://www.bilibili.com'
    if ($query['gourl']) {
        try { $gourl = [Uri]::UnescapeDataString($query['gourl']) } catch { }
    }

    $ticketRaw = $ticket
    try { $ticketRaw = [Uri]::UnescapeDataString($ticket) } catch { }
    $t = [Uri]::EscapeDataString($ticketRaw)
    $g = [Uri]::EscapeDataString($gourl)

    if ($DebugLogin) {
        $suHost = ''
        $suPath = ''
        try { $su = [Uri]$SuccessUrl; $suHost = $su.Host; $suPath = $su.AbsolutePath } catch { }
        $gHost = ''
        $gPath = ''
        try { $gu = [Uri]$gourl; $gHost = $gu.Host; $gPath = $gu.AbsolutePath } catch { }
        Write-Info ("[debug] 轮询返回地址: {0}{1}" -f $suHost, $suPath)
        Write-Info ("[debug] ticket 长度: {0}，gourl: {1}{2}" -f $ticketRaw.Length, $gHost, $gPath)
    }

    $candidates = @(
        $SuccessUrl,
        "https://passport.bilibili.com/x/passport-login/web/crossDomain?ticket=$t&gourl=$g",
        "https://passport.biligame.com/x/passport-login/web/crossDomain?ticket=$t&gourl=$g",
        "https://passport.biligame.com/crossDomain?ticket=$t&gourl=$g"
    )

    $sharedJar = New-BiliCookieJar -WebSession $WebSession
    $dict = @{}
    $haveMainSess = $false
    $allCandidates = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($url in $candidates) {
        if (-not $url -or $seen.ContainsKey($url)) { continue }
        $seen[$url] = $true

        $hostName = ''
        try { $hostName = ([Uri]$url).Host } catch { }
        Write-Info "正在用 ticket 换取登录凭证（$hostName）..."

        try {
            $result = Get-CrossDomainCookies -Url $url -WebSession $WebSession -CookieJar $sharedJar
        } catch {
            $errMsg = [string]$_.Exception.Message
            $errMsg = $errMsg -replace 'ticket=[^&\s]+', 'ticket=***'
            Write-Warn2 "换取失败: $errMsg"
            continue
        }

        foreach ($c in $result.CandidateSets) {
            [void]$allCandidates.Add([pscustomobject]@{
                Source  = ("{0} / {1}" -f $hostName, $c.Source)
                Cookies = $c.Cookies
            })
        }

        if ($result.Cookies.ContainsKey('SESSDATA') -and $result.Cookies['SESSDATA']) {
            [void]$allCandidates.Add([pscustomobject]@{
                Source  = ("{0} / 合并结果" -f $hostName)
                Cookies = $result.Cookies
            })
            # 只有真正从 api.bilibili.com 域拿到的新 SESSDATA 才作为主结果；
            # 游戏域的同名 Cookie 仍会保留为候选，但不覆盖主结果。
            if ($result.NewApiSess -and -not $haveMainSess) {
                $dict = $result.Cookies
                $haveMainSess = $true
            }
        } else {
            foreach ($key in $result.Cookies.Keys) {
                if (-not $dict.ContainsKey($key) -or -not $dict[$key]) {
                    $dict[$key] = $result.Cookies[$key]
                }
            }
        }
    }

    return [pscustomobject]@{
        Cookies       = $dict
        CandidateSets = $allCandidates
    }
}

# ----------------------------------------------------------------------
# 二维码页面（本地渲染，不把登录链接发给第三方）
# ----------------------------------------------------------------------
function New-QrPage {
    param(
        [string]$Url,
        [string]$Path = $QrHtmlPath
    )

    if (-not (Test-Path -LiteralPath $QrLibPath)) {
        throw "缺少本地二维码库: $QrLibPath`n请确认 qrcode.js 与脚本在同一个目录。"
    }

    $safeUrl = $Url.Replace('\', '\\').Replace('"', '\"')
    $qrLib = Get-Content -LiteralPath $QrLibPath -Raw -Encoding UTF8

    $html = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BiliNCM-Bot 扫码登录</title>
<style>
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: radial-gradient(circle at 50% 0%, #1b2230 0%, #0d1015 60%);
    font-family: "Microsoft YaHei", "PingFang SC", system-ui, -apple-system, sans-serif;
    color: #e8ebf2;
  }
  .card {
    width: min(92vw, 520px); padding: 30px 30px 24px; text-align: center;
    background: #171b23; border: 1px solid #2a3140; border-radius: 22px;
    box-shadow: 0 28px 70px rgba(0, 0, 0, .5);
  }
  .brand { font-size: 12px; letter-spacing: .22em; color: #78a2ff; text-transform: uppercase; margin-bottom: 12px; }
  h1 { font-size: 25px; line-height: 1.3; margin: 0 0 10px; font-weight: 700; }
  .tip { font-size: 14px; line-height: 1.75; color: #b7c0d0; margin: 0 0 22px; }
  .tip b { color: #ffffff; }
  .qr {
    display: inline-block; padding: 14px; line-height: 0; background: #ffffff;
    border-radius: 16px; box-shadow: 0 10px 30px rgba(0, 0, 0, .35);
  }
  .qr svg { width: 68vmin; max-width: 380px; height: auto; display: block; }
  .hint { font-size: 12px; line-height: 1.9; color: #8792a6; margin: 20px 0 0; }
  .err { color: #ff7070; font-size: 13px; line-height: 1.6; margin: 12px 0 0; }
</style>
</head>
<body>
  <div class="card">
    <div class="brand">BiliNCM-Bot</div>
    <h1>扫码登录 B 站</h1>
    <p class="tip">请使用手机 <b>哔哩哔哩 App</b> 扫描下方二维码，<br>并在手机上点击「确认登录」。</p>
    <div id="qr" class="qr"></div>
    <p class="hint">扫码后请回到黑色命令行窗口，脚本会自动继续。<br>登录成功后本页面可以直接关闭。</p>
    <p id="err" class="err"></p>
  </div>
<script>
__QR_LIB__
</script>
<script>
(function () {
  var url = "__QR_URL__";
  var box = document.getElementById('qr');
  try {
    if (typeof qrcode !== 'function') { throw new Error('二维码库加载失败'); }
    var qr = qrcode(0, 'M');
    qr.addData(url);
    qr.make();
    box.innerHTML = qr.createSvgTag({ cellSize: 9, margin: 36, scalable: true });
  } catch (e) {
    document.getElementById('err').textContent = '二维码生成失败: ' + e.message;
  }
})();
</script>
</body>
</html>
'@

    $html = $html.Replace('__QR_URL__', $safeUrl).Replace('__QR_LIB__', $qrLib)

    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $html, $utf8)
}

# ----------------------------------------------------------------------
# config.json
# ----------------------------------------------------------------------
function Save-BiliConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Cookie,
        [Parameter(Mandatory = $true)][long]$Uid,
        [string]$Path = $ConfigPath
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $cfg = [ordered]@{}

    if (Test-Path -LiteralPath $Path) {
        try {
            $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch {
            $bak = '{0}.bak-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
            try { Copy-Item -LiteralPath $Path -Destination $bak -Force } catch { }
            Write-Warn2 "原 config.json 无法解析，已备份为: $bak"
        }
    }

    $cfg['BiliCookie'] = $Cookie
    $cfg['BiliUid'] = $Uid
    if (-not $cfg.Contains('RoomId')) { $cfg['RoomId'] = 0 }

    $json = $cfg | ConvertTo-Json -Depth 20
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $json, $utf8)
}

# ----------------------------------------------------------------------
# 用多种 Cookie 组合验证登录，兼容不同版本的 Cookie 处理方式
# ----------------------------------------------------------------------
function Find-WorkingCookie {
    param(
        [hashtable]$Cookies,
        [string]$FullCookie
    )

    $attempts = New-Object System.Collections.ArrayList
    $seen = @{}

    $addAttempt = {
        param([string]$Name, [hashtable]$Set)
        if (-not $Set.ContainsKey('SESSDATA') -or -not $Set['SESSDATA']) { return }
        $cookieText = Get-CookieString -Cookies $Set
        if (-not $cookieText -or $seen.ContainsKey($cookieText)) { return }
        $seen[$cookieText] = $true
        [void]$attempts.Add([pscustomobject]@{ Name = $Name; Cookie = $cookieText; Cookies = $Set })
    }

    $minimal = @{}
    foreach ($key in @('SESSDATA', 'bili_jct', 'DedeUserID', 'DedeUserID__ckMd5', 'ac_time_value')) {
        if ($Cookies.ContainsKey($key) -and $Cookies[$key]) { $minimal[$key] = $Cookies[$key] }
    }

    $sessOnly = @{}
    if ($Cookies.ContainsKey('SESSDATA') -and $Cookies['SESSDATA']) {
        $sessOnly['SESSDATA'] = $Cookies['SESSDATA']
    }

    # 优先精简集合：如果完整集合里的额外 Cookie 触发风控，精简集合仍可能通过
    & $addAttempt '精简 Cookie' $minimal
    & $addAttempt '完整 Cookie' $Cookies
    & $addAttempt '仅 SESSDATA' $sessOnly

    if ($Cookies.ContainsKey('SESSDATA') -and $Cookies['SESSDATA']) {
        $rawSess = [string]$Cookies['SESSDATA']

        # URL 解码变体
        $decodedSess = $rawSess
        try { $decodedSess = [Uri]::UnescapeDataString($rawSess) } catch { }
        if ($decodedSess -and $decodedSess -ne $rawSess) {
            $decodedMinimal = $minimal.Clone()
            $decodedMinimal['SESSDATA'] = $decodedSess
            & $addAttempt 'SESSDATA 解码（精简）' $decodedMinimal

            $decodedFull = $Cookies.Clone()
            $decodedFull['SESSDATA'] = $decodedSess
            & $addAttempt 'SESSDATA 解码（完整）' $decodedFull

            $decodedSessOnly = @{}
            $decodedSessOnly['SESSDATA'] = $decodedSess
            & $addAttempt 'SESSDATA 解码（单独）' $decodedSessOnly
        }

        # 某些 Set-Cookie 会把值用双引号包起来；Cookie 头里不应带引号
        if ($rawSess.Length -ge 2 -and $rawSess.StartsWith('"') -and $rawSess.EndsWith('"')) {
            $unquotedSess = $rawSess.Substring(1, $rawSess.Length - 2)
            $unquotedMinimal = $minimal.Clone()
            $unquotedMinimal['SESSDATA'] = $unquotedSess
            & $addAttempt 'SESSDATA 去引号（精简）' $unquotedMinimal

            $unquotedFull = $Cookies.Clone()
            $unquotedFull['SESSDATA'] = $unquotedSess
            & $addAttempt 'SESSDATA 去引号（完整）' $unquotedFull

            $unquotedSessOnly = @{}
            $unquotedSessOnly['SESSDATA'] = $unquotedSess
            & $addAttempt 'SESSDATA 去引号（单独）' $unquotedSessOnly
        }

        # 逗号编码变体（参考已知可用的修复脚本：.replace(",", "%2C")）
        if ($rawSess -match ',') {
            $encodedSess = $rawSess -replace ',', '%2C'
            $encodedMinimal = $minimal.Clone()
            $encodedMinimal['SESSDATA'] = $encodedSess
            & $addAttempt 'SESSDATA 逗号编码（精简）' $encodedMinimal

            $encodedFull = $Cookies.Clone()
            $encodedFull['SESSDATA'] = $encodedSess
            & $addAttempt 'SESSDATA 逗号编码（完整）' $encodedFull

            $encodedSessOnly = @{}
            $encodedSessOnly['SESSDATA'] = $encodedSess
            & $addAttempt 'SESSDATA 逗号编码（单独）' $encodedSessOnly
        }
    }

    $lastNav = $null
    foreach ($attempt in $attempts) {
        if ($DebugLogin) { Write-Info ("[debug] 登录校验方式: {0}" -f $attempt.Name) }
        $nav = Test-BiliLogin -Cookie $attempt.Cookie
        $lastNav = $nav

        if ($nav.Status -eq 'Valid') {
            return [pscustomobject]@{
                Success = $true
                Nav     = $nav
                Cookie  = $attempt.Cookie
                Cookies = $attempt.Cookies
                Method  = $attempt.Name
            }
        }

        if ($DebugLogin) {
            Write-Info ("[debug]   {0}: code={1} {2}" -f $nav.Status, $nav.Code, $nav.Message)
        }
    }

    return [pscustomobject]@{
        Success = $false
        Nav     = $lastNav
        Cookie  = $FullCookie
        Cookies = $Cookies
        Method  = ''
    }
}

# ----------------------------------------------------------------------
# 扫码登录主流程
# ----------------------------------------------------------------------
function Invoke-BiliQrLogin {

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Title "扫码登录（第 $attempt/3 次）"

        $session = New-Object -TypeName Microsoft.PowerShell.Commands.WebRequestSession
        $qr = $null
        try { $qr = New-BiliQr -WebSession $session } catch { Write-Err $_.Exception.Message; return $null }

        New-QrPage -Url $qr.Url
        Write-Info "二维码页面: $QrHtmlPath"

        try {
            Start-Process -FilePath $QrHtmlPath | Out-Null
        } catch {
            $browserCandidates = @(
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
            )
            $opened = $false
            foreach ($browser in $browserCandidates) {
                if ($browser -and (Test-Path -LiteralPath $browser)) {
                    try {
                        Start-Process -FilePath $browser -ArgumentList ('"{0}"' -f $QrHtmlPath) | Out-Null
                        $opened = $true
                        break
                    } catch { }
                }
            }
            if (-not $opened) { Write-Warn2 '无法自动打开浏览器，请手动双击上面的 HTML 文件。' }
        }

        Write-Ok '已打开二维码页面，请使用手机 B 站 App 扫码并确认。'

        $poll = $null
        try { $poll = Wait-BiliQr -Key $qr.Key -WebSession $session } catch { Write-Err $_.Exception.Message; return $null }

        if ($poll.Status -eq 'Expired' -or $poll.Status -eq 'Timeout') {
            if ($poll.Status -eq 'Expired') { Write-Warn2 '二维码已过期。' }
            else { Write-Warn2 '等待扫码超时。' }

            if ($attempt -ge 3) { break }
            $answer = Read-Host '是否重新生成二维码？[Y/n]'
            if ($answer -match '^(n|no)$') { return $null }
            continue
        }

        # 扫码成功
        Write-Ok '手机已确认，正在提取登录凭证...'
        $resolved = Resolve-BiliLoginCookies -SuccessUrl $poll.Url -WebSession $session
        $cookies = $resolved.Cookies
        $candidateSets = $resolved.CandidateSets
        if (-not $candidateSets) { $candidateSets = New-Object System.Collections.ArrayList }

        # 轮询响应本身也可能带 Set-Cookie（旧版行为），作为兜底合并进来
        if ($poll.Cookies -and $poll.Cookies.Count -gt 0) {
            foreach ($key in $poll.Cookies.Keys) {
                if (-not $cookies.ContainsKey($key) -or -not $cookies[$key]) {
                    $cookies[$key] = $poll.Cookies[$key]
                }
            }
            if ($poll.Cookies.ContainsKey('SESSDATA') -and $poll.Cookies['SESSDATA']) {
                [void]$candidateSets.Add([pscustomobject]@{
                    Source  = '轮询响应'
                    Cookies = $poll.Cookies
                })
            }
        }

        if (-not $cookies.ContainsKey('SESSDATA') -or -not $cookies['SESSDATA']) {
            Write-Err '扫码确认成功，但没能取得 SESSDATA。'
            Write-Info '这通常意味着 B 站登录接口再次改版，请把本窗口的输出反馈给脚本维护者。'
            return $null
        }

        Add-BuvidCookies -Cookies $cookies
        $buvid3 = ''
        $buvid4 = ''
        if ($cookies.ContainsKey('buvid3')) { $buvid3 = [string]$cookies['buvid3'] }
        if ($cookies.ContainsKey('buvid4')) { $buvid4 = [string]$cookies['buvid4'] }

        $cookieString = Get-CookieString -Cookies $cookies
        $cookieNames = ($cookies.Keys | Sort-Object) -join ', '
        Write-Info "取得 Cookie: $cookieNames"
        Write-Info ("SESSDATA 长度: {0}" -f ([string]$cookies['SESSDATA']).Length)
        if ($cookies.ContainsKey('DedeUserID')) {
            Write-Info ("DedeUserID: {0}" -f $cookies['DedeUserID'])
        }

        # 合并结果本身也作为一个候选
        [void]$candidateSets.Add([pscustomobject]@{
            Source  = '合并结果'
            Cookies = $cookies
        })

        $uid = 0
        if ($cookies.ContainsKey('DedeUserID')) {
            [void][long]::TryParse([string]$cookies['DedeUserID'], [ref]$uid)
        }

        Write-Info '正在验证登录状态...'

        $totalCandidates = 0
        foreach ($c in $candidateSets) {
            if ($c.Cookies.ContainsKey('SESSDATA') -and $c.Cookies['SESSDATA']) { $totalCandidates++ }
        }

        $check = $null
        $nav = $null
        $seenSignatures = @{}
        $candidateIndex = 0

        foreach ($candidate in $candidateSets) {
            if (-not $candidate.Cookies.ContainsKey('SESSDATA') -or -not $candidate.Cookies['SESSDATA']) { continue }

            $set = @{}
            foreach ($key in $candidate.Cookies.Keys) { $set[$key] = $candidate.Cookies[$key] }
            if ($poll.Cookies -and $poll.Cookies.Count -gt 0) {
                foreach ($key in $poll.Cookies.Keys) {
                    if (-not $set.ContainsKey($key) -or -not $set[$key]) { $set[$key] = $poll.Cookies[$key] }
                }
            }
            if ($buvid3 -and -not $set.ContainsKey('buvid3')) { $set['buvid3'] = $buvid3 }
            if ($buvid4 -and -not $set.ContainsKey('buvid4')) { $set['buvid4'] = $buvid4 }

            # 相同 SESSDATA/DedeUserID/bili_jct/buvid3 的候选只试一次，避免无意义的重复请求
            $signature = '{0}|{1}|{2}|{3}' -f [string]$set['SESSDATA'], [string]$set['DedeUserID'], [string]$set['bili_jct'], [string]$set['buvid3']
            if ($seenSignatures.ContainsKey($signature)) { continue }
            $seenSignatures[$signature] = $true

            $candidateIndex++
            Write-Info ("验证候选 {0}/{1}（来源: {2}）..." -f $candidateIndex, $totalCandidates, $candidate.Source)

            $fullCookie = Get-CookieString -Cookies $set
            $check = Find-WorkingCookie -Cookies $set -FullCookie $fullCookie
            $nav = $check.Nav

            if ($check.Success) {
                $cookieString = $check.Cookie
                $cookies = $check.Cookies
                $uid = $nav.Uid
                Write-Ok "登录成功，UID: $uid（校验方式: $($check.Method)）"
                break
            }

            if ($DebugLogin -and $nav) {
                Write-Info ("[debug] 候选未通过: code={0} {1}" -f $nav.Code, $nav.Message)
            }
        }

        if (-not $check -or -not $check.Success) {
            if ($nav -and $nav.Status -eq 'Invalid') {
                Write-Err "B 站返回「账号未登录」（code=$($nav.Code) $($nav.Message)），所有候选 Cookie 均无效。"
                Write-Info '请重新扫码；如果反复出现，请用 -DebugLogin 运行并把输出发给维护者。'
                return $null
            }
            if ($nav) {
                Write-Warn2 "登录校验返回异常（code=$($nav.Code) $($nav.Message)），仍将保存凭证。"
            } else {
                Write-Err '登录校验没有返回结果。'
                return $null
            }
        }

        if ($uid -le 0) {
            Write-Err '无法获取 UID，登录失败。'
            return $null
        }

        return [pscustomobject]@{
            Cookie = $cookieString
            Uid    = [long]$uid
        }
    }

    Write-Err '扫码登录未完成。'
    return $null
}

# ----------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------
function Invoke-Main {
    Write-Title 'BiliNCM-Bot 登录助手'
    Write-Info "安装目录: $Root"
    Write-Info "配置文件: $ConfigPath"

    Wait-BotClosed

    # 清理上次可能残留的二维码页面
    if (Test-Path -LiteralPath $QrHtmlPath) {
        Remove-Item -LiteralPath $QrHtmlPath -Force -ErrorAction SilentlyContinue
    }

    $cookie = ''
    $uid = 0

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cookie = [string]$cfg.BiliCookie
            try { $uid = [long]$cfg.BiliUid } catch { $uid = 0 }
        } catch {
            Write-Warn2 'config.json 解析失败，将重新进行扫码登录。'
        }
    }

    if ($cookie -and $cookie -match 'SESSDATA=[^;]+') {
        $dict = ConvertFrom-CookieString -Cookie $cookie
        Add-BuvidCookies -Cookies $dict
        $cookieNew = Get-CookieString -Cookies $dict

        Write-Info '正在验证现有登录状态...'
        $nav = Test-BiliLogin -Cookie $cookieNew

        # 现有 Cookie 也可能因为附带 Cookie 触发风控，必要时尝试精简组合
        if ($nav.Status -eq 'Invalid') {
            $existingCheck = Find-WorkingCookie -Cookies $dict -FullCookie $cookieNew
            $nav = $existingCheck.Nav
            if ($existingCheck.Success) {
                $cookieNew = $existingCheck.Cookie
                $dict = $existingCheck.Cookies
            }
        }

        switch ($nav.Status) {
            'Valid' {
                Write-Ok "登录状态有效，UID: $($nav.Uid)"
                if ($uid -ne $nav.Uid -or $cookieNew -ne $cookie) {
                    Save-BiliConfig -Cookie $cookieNew -Uid $nav.Uid
                    Write-Info '已更新 config.json 中的登录信息。'
                }
                if ($NoLaunch) { Write-Ok '已指定 -NoLaunch，不启动点歌机。'; return 0 }
                Start-BiliBot
                return 0
            }
            'Invalid' {
                Write-Warn2 '登录已失效，需要重新扫码。'
            }
            'NetworkError' {
                Write-Warn2 "无法连接 B 站验证登录状态: $($nav.Message)"
                $answer = Read-Host '是否仍然启动点歌机？[Y/n]'
                if ($answer -match '^(n|no)$') { return 1 }
                if ($NoLaunch) { return 0 }
                Start-BiliBot
                return 0
            }
            default {
                Write-Warn2 "验证返回异常（code=$($nav.Code) $($nav.Message)）。"
                $answer = Read-Host '是否重新扫码登录？[y/N]'
                if ($answer -match '^(y|yes)$') {
                    # 继续走扫码流程
                } else {
                    if ($NoLaunch) { return 0 }
                    Start-BiliBot
                    return 0
                }
            }
        }
    } else {
        Write-Info '没有检测到已保存的登录信息。'
    }

    $login = Invoke-BiliQrLogin
    if (-not $login) { return 1 }

    Save-BiliConfig -Cookie $login.Cookie -Uid $login.Uid
    Write-Ok '登录凭证已保存到 config.json。'

    # 登录已完成，删除含有临时登录链接的二维码页面
    if (Test-Path -LiteralPath $QrHtmlPath) {
        Remove-Item -LiteralPath $QrHtmlPath -Force -ErrorAction SilentlyContinue
    }

    if ($NoLaunch) { Write-Ok '已指定 -NoLaunch，不启动点歌机。'; return 0 }
    Start-BiliBot
    return 0
}

# ----------------------------------------------------------------------
# 自检
# ----------------------------------------------------------------------
function Invoke-SelfTest {
    $script:testFail = 0

    function Assert-True {
        param([bool]$Condition, [string]$Name)
        if ($Condition) {
            Write-Host "  [PASS] $Name" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] $Name" -ForegroundColor Red
            $script:testFail++
        }
    }

    Write-Title 'SelfTest'

    $legacy = 'https://passport.biligame.com/crossDomain?DedeUserID=123&DedeUserID__ckMd5=abc&SESSDATA=xyz%2C1%2A2&bili_jct=jct'
    $q = ConvertFrom-QueryString -Url $legacy
    Assert-True ($q['SESSDATA'] -eq 'xyz%2C1%2A2') '解析旧版 SESSDATA（保留原始编码）'
    Assert-True ($q['DedeUserID'] -eq '123') '解析旧版 DedeUserID'

    $ticketUrl = 'https://passport.biligame.com/x/passport-login/web/crossDomain?ticket=abc123&gourl=https%3A%2F%2Fwww.bilibili.com'
    $t = ConvertFrom-QueryString -Url $ticketUrl
    Assert-True ($t['ticket'] -eq 'abc123') '解析新版 ticket'

    $c = ConvertFrom-CookieString -Cookie 'SESSDATA=abc%2Cdef; bili_jct=jj; DedeUserID=42'
    Assert-True ($c['SESSDATA'] -eq 'abc%2Cdef') '解析 Cookie 字符串'
    $cs = Get-CookieString -Cookies $c
    Assert-True ($cs -match 'SESSDATA=abc%2Cdef') '重建 Cookie 字符串'

    New-QrPage -Url 'https://example.com/test?a=1&b=2'
    Assert-True (Test-Path -LiteralPath $QrHtmlPath) '生成二维码 HTML'
    $html = Get-Content -LiteralPath $QrHtmlPath -Raw -Encoding UTF8
    Assert-True ($html.Contains('https://example.com/test?a=1&b=2')) '二维码 HTML 包含登录 URL'

    $tmp = Join-Path $env:TEMP ('BiliLoginFix-selftest-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Save-BiliConfig -Cookie 'SESSDATA=x; bili_jct=y' -Uid 42 -Path $tmp
        $o = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ([string]$o.BiliCookie -eq 'SESSDATA=x; bili_jct=y') '写入 config.json 的 BiliCookie'
        Assert-True ([long]$o.BiliUid -eq 42) '写入 config.json 的 BiliUid'
        Assert-True ([long]$o.RoomId -eq 0) '写入默认 RoomId'
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }

    if (Test-Path -LiteralPath $QrHtmlPath) {
        try { Remove-Item -LiteralPath $QrHtmlPath -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host ''
    if ($script:testFail -eq 0) {
        Write-Ok 'SelfTest 全部通过。'
        return 0
    }
    Write-Err "SelfTest 有 $($script:testFail) 项失败。"
    return 1
}

# ----------------------------------------------------------------------
# 入口
# ----------------------------------------------------------------------
$script:TranscriptStarted = $false
if ($DebugLogin) {
    try {
        Start-Transcript -Path (Join-Path $Root 'login-debug.log') -Force | Out-Null
        $script:TranscriptStarted = $true
    } catch { }
}

function Stop-DebugTranscript {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:TranscriptStarted = $false
    }
}

try {
    if ($TestQr) {
        $session = New-Object -TypeName Microsoft.PowerShell.Commands.WebRequestSession
        $qr = New-BiliQr -WebSession $session
        Write-Info ("二维码主机: {0}，URL 长度: {1}" -f ([Uri]$qr.Url).Host, $qr.Url.Length)
        New-QrPage -Url $qr.Url
        Write-Info "二维码页面: $QrHtmlPath"
        $poll = Wait-BiliQr -Key $qr.Key -TimeoutSeconds 6 -WebSession $session
        Write-Info "轮询结果: $($poll.Status)"
        Stop-DebugTranscript
        exit 0
    }

    if ($SelfTest) {
        $rc = Invoke-SelfTest
        Stop-DebugTranscript
        exit $rc
    }

    $rc = Invoke-Main
    if ($rc -ne 0) {
        Write-Host ''
        [void](Read-Host '按回车退出')
    }
    Stop-DebugTranscript
    exit $rc
} catch {
    Write-Host ''
    Write-Err "发生错误: $($_.Exception.Message)"
    Stop-DebugTranscript
    Write-Host ''
    [void](Read-Host '按回车退出')
    exit 1
} finally {
    Stop-DebugTranscript
}
