#requires -Version 5.1
<#
    只读 CDP 探针
    ------------------------------------------------------------------
    在网易云已经带 --remote-debugging-port=9222 启动时运行。

    它只做读取/检查：
      1. 读取 /json，找到 orpheus 页面；
      2. 通过 CDP 读取 location.href、#root/#portal_root、React root、Redux store；
      3. 执行 bot 同款 _ensureStore()，但不 dispatch 任何 action。

    不会加入播放列表、不会播放/暂停、不会修改网易云数据。
#>

[CmdletBinding()]
param(
    [int]$CdpPort = 9222,
    [string]$OutFile = '',
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::InputEncoding  = [Text.Encoding]::UTF8
} catch { }
try { Add-Type -AssemblyName System.Net.WebSockets | Out-Null } catch { }

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $PSScriptRoot 'cdp-probe.log'
}

$script:LogToFile = -not $NoLog

function Write-Probe {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Gray }
    }
    if ($script:LogToFile) {
        try { Add-Content -LiteralPath $OutFile -Value $line -Encoding UTF8 } catch { }
    }
}

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

function Get-CdpPageTargets {
    $text = Invoke-Utf8Http -Url ("http://127.0.0.1:{0}/json" -f $CdpPort) -TimeoutSec 3
    $targets = @($text | ConvertFrom-Json)
    return @($targets | Where-Object {
        $_.type -eq 'page' -and
        ([string]$_.url -match 'orpheus') -and
        (-not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl))
    })
}

function Invoke-CdpEvaluate {
    param(
        [string]$WebSocketUrl,
        [string]$Expression,
        [int]$TimeoutSeconds = 8
    )

    $wsUrl = $WebSocketUrl -replace '^ws://localhost:', 'ws://127.0.0.1:'
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutSeconds * 1000)

    try {
        $ws.ConnectAsync([Uri]$wsUrl, $cts.Token).GetAwaiter().GetResult()

        $payload = @{
            id     = 1
            method = 'Runtime.evaluate'
            params = @{
                expression    = $Expression
                returnByValue = $true
                awaitPromise  = $false
            }
        } | ConvertTo-Json -Depth 20 -Compress

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [System.ArraySegment[byte]]::new($bytes)
        $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $buffer = New-Object byte[] 16384
            $ms = New-Object System.IO.MemoryStream
            $closed = $false

            do {
                $recvSegment = [System.ArraySegment[byte]]::new($buffer)
                $recv = $ws.ReceiveAsync($recvSegment, $cts.Token).GetAwaiter().GetResult()
                if ($recv.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    $closed = $true
                    break
                }
                $ms.Write($buffer, 0, $recv.Count)
            } while (-not $recv.EndOfMessage)

            $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
            $ms.Dispose()

            if ($closed) { throw 'DevTools WebSocket 在返回结果前关闭了' }
            if ([string]::IsNullOrWhiteSpace($text)) { continue }

            try { $msg = $text | ConvertFrom-Json } catch { continue }
            if ($msg.id -eq 1) { return $msg }
        }

        throw '没有收到 Runtime.evaluate 的响应'
    } finally {
        try { $ws.Dispose() } catch { }
        try { $cts.Dispose() } catch { }
    }
}

function Get-EvaluateValue {
    param([object]$Response)

    if ($Response.result -and $Response.result.exceptionDetails) {
        $details = $Response.result.exceptionDetails | ConvertTo-Json -Depth 10 -Compress
        throw ("JS 异常: " + $details)
    }

    if ($Response.result -and $Response.result.result) {
        $inner = $Response.result.result
        $valueProp = $inner.PSObject.Properties['value']
        if ($valueProp) { return [string]$valueProp.Value }
        $descProp = $inner.PSObject.Properties['description']
        if ($descProp) { return [string]$descProp.Value }
    }

    return ($Response | ConvertTo-Json -Depth 10 -Compress)
}

$uiExpression = @'
(() => {
  const portal = document.querySelector('#portal_root');
  const el = document.querySelector('#root');
  const portalRoot = portal && portal._reactRootContainer && portal._reactRootContainer._internalRoot;
  const rootElRoot = el && el._reactRootContainer && el._reactRootContainer._internalRoot;
  const root = window._fiberRoot || portalRoot || rootElRoot;
  const store = window._reduxStore;
  return JSON.stringify({
    href: location.href,
    title: document.title,
    readyState: document.readyState,
    hasRoot: !!el,
    hasPortalRoot: !!portal,
    hasPortalReactRoot: !!portalRoot,
    hasRootReactRoot: !!rootElRoot,
    hasFiberRoot: !!root,
    hasReduxStore: !!store,
    debugLog: (window.__debug_store_log || []).slice(-5)
  });
})()
'@

$storeExpression = @'
(() => {
  function _ensureStore() {
    if (window._reduxStore) return true;
    const portal = document.querySelector('#portal_root');
    const el = document.querySelector('#root');
    const root = window._fiberRoot ||
      (portal && portal._reactRootContainer && portal._reactRootContainer._internalRoot) ||
      (el && el._reactRootContainer && el._reactRootContainer._internalRoot);
    if (!root) return false;
    window._fiberRoot = root;
    let queue = [root.current || root];
    while (queue.length > 0) {
      let node = queue.shift();
      if (!node) continue;
      if (node.memoizedProps && node.memoizedProps.store) { window._reduxStore = node.memoizedProps.store; return true; }
      if (node.stateNode && node.stateNode.store) { window._reduxStore = node.stateNode.store; return true; }
      let child = node.child;
      while (child) { queue.push(child); child = child.sibling; }
    }
    return false;
  }

  const before = (window.__debug_store_log || []).slice(-5);
  let ok = false;
  let error = null;
  try { ok = _ensureStore(); } catch (e) { error = String(e && (e.stack || e)); }
  const store = window._reduxStore;
  let keys = [];
  try { if (store) keys = Object.keys(store); } catch (e) { }

  return JSON.stringify({
    ok: ok,
    hasStore: !!store,
    hasDispatch: !!(store && typeof store.dispatch === 'function'),
    storeKeys: keys,
    error: error,
    debugLogBefore: before,
    debugLogAfter: (window.__debug_store_log || []).slice(-5)
  });
})()
'@

Write-Probe '=== 只读 CDP 探针 ==='
Write-Probe ("端口: {0}" -f $CdpPort)
Write-Probe ("日志: {0}" -f $(if ($script:LogToFile) { $OutFile } else { '<不写文件>' }))

$botProcs = @(Get-Process -Name 'BiliNCM-Bot' -ErrorAction SilentlyContinue)
if ($botProcs.Count -gt 0) {
    Write-Probe '检测到 bot 正在运行；探针会建立额外的 CDP 连接，可能短暂影响切歌雷达。' 'WARN'
}

if (-not (Test-TcpPort -Port $CdpPort -TimeoutMs 1200)) {
    Write-Probe ("端口 {0} 未监听；当前网易云不是调试模式，或还没有启动。" -f $CdpPort) 'ERROR'
    exit 2
}

try {
    $targets = @(Get-CdpPageTargets)
} catch {
    Write-Probe ("读取 http://127.0.0.1:{0}/json 失败: {1}" -f $CdpPort, $_.Exception.Message) 'ERROR'
    exit 3
}

if ($targets.Count -eq 0) {
    Write-Probe '端口已监听，但没有找到 orpheus 页面目标。' 'ERROR'
    try {
        $allText = Invoke-Utf8Http -Url ("http://127.0.0.1:{0}/json" -f $CdpPort) -TimeoutSec 3
        $all = @($allText | ConvertFrom-Json)
        foreach ($t in $all) {
            Write-Probe ("target: type={0}; url={1}" -f ([string]$t.type), ([string]$t.url)) 'WARN'
        }
    } catch { }
    exit 3
}

$foundStore = $false
foreach ($target in $targets) {
    Write-Probe ''
    Write-Probe ("页面: {0}" -f ([string]$target.url))
    Write-Probe ("WS: {0}" -f ([string]$target.webSocketDebuggerUrl))

    try {
        $uiResponse = Invoke-CdpEvaluate -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $uiExpression
        $uiText = Get-EvaluateValue -Response $uiResponse
        Write-Probe ("UI: {0}" -f $uiText) 'OK'

        $storeResponse = Invoke-CdpEvaluate -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $storeExpression
        $storeText = Get-EvaluateValue -Response $storeResponse
        Write-Probe ("STORE: {0}" -f $storeText) 'OK'

        try {
            $storeObj = $storeText | ConvertFrom-Json
            if ($storeObj.hasStore) { $foundStore = $true }
        } catch { }
    } catch {
        Write-Probe ("探针失败: {0}" -f $_.Exception.Message) 'ERROR'
    }
}

if (-not $foundStore) {
    Write-Probe ''
    Write-Probe '结果：没有找到可用 Redux store。若 UI 中 hasPortalRoot/hasPortalReactRoot 为 false，优先检查页面目标；若 hasFiberRoot 为 true 但 hasStore 为 false，则属于挖树/版本兼容问题。' 'WARN'
    exit 4
}

Write-Probe ''
Write-Probe '结果：已找到 Redux store，说明 CDP 连接和 _ensureStore 基本正常。' 'OK'
exit 0
