#requires -Version 5.1
<#
    BiliNCM-Bot external NCM companion / priority queue
    ------------------------------------------------------------------
    The bot's own auto-play (CDP radar + monitor) is kept paused so it
    never force-plays or steals the current song. This companion owns
    the NCM queue instead:

      - track_queue is the full playing list (history + current +
        upcoming); every pending/played decision is relative to the
        current index, never to list index 0;
      - new requests (d) are inserted after the last pending d, or
        immediately after the current song when there is no pending d;
      - re-requests of an existing song are moved with MF.r4 instead of
        being added again, so there is never a second copy;
      - the current song is never cut, moved, skipped or force-played;
      - NCM order is read back every poll, so manual drag/insert/delete
        is respected and never normalised;
      - duplicate bot queue entries are merged, never added twice;
      - an overlay state file is written for BiliNCM-Overlay.ps1.

    Queue additions use NCM's normal high-level queue-add path
    (MF.Xn). Moves use MF.r4 with the existing queue wrappers. No
    force-play, no skip, no direct track_queue mutation by hand.

    It does not modify the bot, current\ files, or the NCM installation.

    Modes:
      Normal                  : background loop started by the launcher.
      -BotPort <n>            : bot API port (default 5555; test harness use).
      -TestSongId <id>        : queue one song and exit.
      -TestOffset <n>         : offset for -TestSongId (-2 = omit offset,
                                -1 = append, 0+ = raw queue index).
      -ProbeNcm               : dump raw NCM queue/current state and exit.
#>

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [int]$CdpPort = 9222,
    [int]$BotPort = 5555,
    [int]$PollMilliseconds = 1000,
    [int]$IdleExitSeconds = 60,
    [string]$TestSongId = '',
    [int]$TestOffset = -1,
    [switch]$ProbeNcm
)

$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::InputEncoding  = [Text.Encoding]::UTF8
} catch { }

try { Add-Type -AssemblyName System.Net.WebSockets | Out-Null } catch { }

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$LogFile = Join-Path $Root 'companion.log'
$OverlayStateFile = Join-Path $Root 'overlay-state.json'
$BotBaseUrl = 'http://localhost:{0}' -f $BotPort

function Write-CompanionLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $line = $line -replace '(?i)(SESSDATA\s*=\s*)[^;\s]+', '$1<redacted>'
    $line = $line -replace '(?i)(BiliCookie\s*[=:]\s*)[^\r\n]+', '$1<redacted>'
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Test-TcpPort {
    param([int]$Port, [int]$TimeoutMs = 700)
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
    param([string]$Url, [int]$TimeoutSec = 3)
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
    try {
        if ($resp.RawContentStream) {
            return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        }
    } catch { }
    return [string]$resp.Content
}

function Get-CdpPageTargets {
    try {
        $text = Invoke-Utf8Http -Url ("http://127.0.0.1:{0}/json" -f $CdpPort) -TimeoutSec 3
        $targets = @($text | ConvertFrom-Json)
        return @($targets | Where-Object {
            $_.type -eq 'page' -and
            ([string]$_.url -match 'orpheus') -and
            (-not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl))
        })
    } catch {
        return @()
    }
}

function Invoke-CdpEvaluate {
    param(
        [string]$WebSocketUrl,
        [string]$Expression,
        [int]$TimeoutSeconds = 30,
        [bool]$AwaitPromise = $true
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
                awaitPromise  = $AwaitPromise
            }
        } | ConvertTo-Json -Depth 20 -Compress

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [System.ArraySegment[byte]]::new($bytes)
        $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null

        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $buffer = New-Object byte[] 262144
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

            if ($closed) { throw 'DevTools WebSocket closed before a response' }
            if ([string]::IsNullOrWhiteSpace($text)) { continue }

            try { $msg = $text | ConvertFrom-Json } catch { continue }
            if ($msg.id -eq 1) { return $msg }
        }

        throw 'No Runtime.evaluate response'
    } finally {
        try { $ws.Dispose() } catch { }
        try { $cts.Dispose() } catch { }
    }
}

function Get-EvaluateJson {
    param([object]$Response)

    if ($Response.result -and $Response.result.exceptionDetails) {
        $details = $Response.result.exceptionDetails | ConvertTo-Json -Depth 10 -Compress
        throw ('JS exception: ' + $details)
    }

    if ($Response.result -and $Response.result.result) {
        $inner = $Response.result.result
        $valueProp = $inner.PSObject.Properties['value']
        if ($valueProp) {
            $text = [string]$valueProp.Value
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return ($text | ConvertFrom-Json)
        }
    }

    return $null
}

$bridgeExpression = @'
(() => {
  const portal = document.querySelector('#portal_root');
  const rootEl = document.querySelector('#root');
  const realRoot = portal && portal._reactRootContainer && portal._reactRootContainer._internalRoot;
  if (realRoot) {
    window._fiberRoot = realRoot;
    if (rootEl && portal._reactRootContainer) {
      rootEl._reactRootContainer = portal._reactRootContainer;
    }
  }
  function ensureStore() {
    if (window._reduxStore) return true;
    const root = window._fiberRoot || realRoot;
    if (!root) return false;
    let queue = [root.current || root];
    while (queue.length > 0) {
      const node = queue.shift();
      if (!node) continue;
      if (node.memoizedProps && node.memoizedProps.store) { window._reduxStore = node.memoizedProps.store; return true; }
      if (node.stateNode && node.stateNode.store) { window._reduxStore = node.stateNode.store; return true; }
      let child = node.child;
      while (child) { queue.push(child); child = child.sibling; }
    }
    return false;
  }
  let ok = false;
  let error = null;
  try { ok = ensureStore(); } catch (e) { error = String(e && (e.stack || e)); }
  return JSON.stringify({
    ok: ok,
    href: location.href,
    hasPortalRoot: !!portal,
    hasReactRoot: !!realRoot,
    hasStore: !!window._reduxStore,
    error: error
  });
})()
'@

# Read-only view of the NCM playing state. track_queue is the full
# playing list (history + current + upcoming); qid is the stable queue
# wrapper id, id is the song id. currentIndex is the index of the
# current song inside that same list.
$stateExpression = @'
(() => {
  function ensureStore() {
    if (window._reduxStore) return true;
    const portal = document.querySelector('#portal_root');
    const realRoot = portal && portal._reactRootContainer && portal._reactRootContainer._internalRoot;
    if (realRoot) window._fiberRoot = realRoot;
    const root = window._fiberRoot || realRoot;
    if (!root) return false;
    let queue = [root.current || root];
    while (queue.length > 0) {
      const node = queue.shift();
      if (!node) continue;
      if (node.memoizedProps && node.memoizedProps.store) { window._reduxStore = node.memoizedProps.store; return true; }
      if (node.stateNode && node.stateNode.store) { window._reduxStore = node.stateNode.store; return true; }
      let child = node.child;
      while (child) { queue.push(child); child = child.sibling; }
    }
    return false;
  }
  if (!ensureStore()) return JSON.stringify({ok:false, error:'no_store'});
  const st = window._reduxStore.getState();
  const m = window.ctl && window.ctl.defPlayer && window.ctl.defPlayer.MF;
  const read = (k) => {
    try {
      if (!m || typeof m.V !== 'function') return [];
      const a = m.V(k);
      return Array.isArray(a) ? a : [];
    } catch (e) { return []; }
  };
  const idOf = (x) => {
    if (!x) return '';
    if (x.tid != null) return String(x.tid);
    if (x.id != null) return String(x.id);
    if (x.track && x.track.id != null) return String(x.track.id);
    return '';
  };
  const qidOf = (x) => {
    if (!x) return '';
    if (x.id != null) return String(x.id);
    if (x.tid != null) return String(x.tid);
    if (x.track && x.track.id != null) return String(x.track.id);
    return '';
  };
  const trackOf = (x) => (x && (x.track || x)) || null;
  const nameOf = (x) => { const t = trackOf(x); return (t && (t.name || t.songName)) || ''; };
  const artistsOf = (x) => {
    const t = trackOf(x);
    const a = (t && (t.artists || t.ar)) || [];
    return a.map(v => v && (v.name || v.nickname)).filter(Boolean).join('/');
  };
  const pack = (x) => {
    const id = idOf(x);
    if (!id) return null;
    return { id: id, qid: qidOf(x), name: nameOf(x), artists: artistsOf(x) };
  };
  const queue = read('track_queue').map(pack).filter(Boolean);
  const cplRaw = (st.playingList && st.playingList.curPlayingList) || [];
  const cpl = cplRaw.map(pack).filter(Boolean);

  let curId = '';
  let curWrapper = '';
  let curStart = '';
  let curState = null;
  let curName = '';
  let curArtists = '';
  try {
    const u = m && typeof m.U === 'function' ? m.U() : null;
    if (u && u.data && u.data.id != null) {
      curId = String(u.data.id);
      curName = u.data.name || '';
      if (Array.isArray(u.data.artists)) {
        curArtists = u.data.artists.map(a => a && a.name).filter(Boolean).join('/');
      }
      if (u.from) {
        if (u.from.id != null) curWrapper = String(u.from.id);
        if (u.from.startlogtime != null) curStart = String(u.from.startlogtime);
      }
      curState = u.state;
    }
  } catch (e) { }
  const stId = st.playing && (st.playing.resourceTrackId || st.playing.onlineResourceId);
  if (!curId && stId != null) curId = String(stId);

  let idx = curWrapper ? queue.findIndex(x => x.qid === curWrapper) : -1;
  let matchedBy = idx >= 0 ? 'wrapper' : '';
  if (idx < 0 && curId) {
    idx = queue.findIndex(x => x.id === curId);
    if (idx >= 0) matchedBy = 'tid';
  }
  const entry = idx >= 0 ? queue[idx] : (cpl.find(x => x.id === curId) || null);
  if (!curName && entry) curName = entry.name;
  if (!curArtists && entry) curArtists = entry.artists;
  const current = curId ? {
    id: curId,
    qid: curWrapper,
    name: curName,
    artists: curArtists,
    start: curStart,
    state: curState
  } : null;
  return JSON.stringify({
    ok: true,
    page: String(performance.timeOrigin || 0),
    current: current,
    currentIndex: idx,
    currentMatchedBy: matchedBy,
    currentWrapper: curWrapper,
    queue: queue,
    playingList: cpl,
    queueLen: queue.length
  });
})()
'@

$addExpressionTemplate = @'
(async () => {
  const id = '__SONG_ID__';
  const mode = '__OFFSET_MODE__';
  const explicitOffset = __OFFSET__;
  const pendingQids = __PENDING_QIDS__;
  const m = window.ctl && window.ctl.defPlayer && window.ctl.defPlayer.MF;
  if (!m) return JSON.stringify({ok:false, error:'no_MF', href:location.href});

  const idOf = (x) => {
    if (!x) return '';
    if (x.tid != null) return String(x.tid);
    if (x.id != null) return String(x.id);
    if (x.track && x.track.id != null) return String(x.track.id);
    return '';
  };
  const qidOf = (x) => {
    if (!x) return '';
    if (x.id != null) return String(x.id);
    if (x.tid != null) return String(x.tid);
    if (x.track && x.track.id != null) return String(x.track.id);
    return '';
  };
  const readQueue = () => {
    try { const a = m.V('track_queue'); return Array.isArray(a) ? a.slice() : []; }
    catch (e) { return []; }
  };
  const readPlaying = () => { try { return m.U(); } catch (e) { return null; } };
  const wid = (x) => qidOf(x);
  const curInfo = (q) => {
    const u = readPlaying();
    let curId = '';
    let curWrapper = '';
    let curStart = '';
    let curState = null;
    if (u && u.data && u.data.id != null) {
      curId = String(u.data.id);
      if (u.from) {
        if (u.from.id != null) curWrapper = String(u.from.id);
        if (u.from.startlogtime != null) curStart = String(u.from.startlogtime);
      }
      curState = u.state;
    }
    let index = curWrapper ? q.findIndex(x => wid(x) === curWrapper) : -1;
    if (index < 0 && curId) index = q.findIndex(x => idOf(x) === curId);
    return { id: curId, wrapper: curWrapper, start: curStart, state: curState, index: index };
  };
  const findAfter = (q, ci) => {
    if (ci.index < 0) return null;
    for (let i = ci.index + 1; i < q.length; i++) {
      if (idOf(q[i]) === id) return { index: i, qid: wid(q[i]) };
    }
    return null;
  };
  const countOf = (q) => q.reduce((n, x) => n + (idOf(x) === id ? 1 : 0), 0);
  const computeAnchor = (q, ci) => {
    if (mode === 'omit') return undefined;
    if (mode === 'append') return q.length;
    if (mode === 'explicit') return Math.max(0, explicitOffset);
    if (ci.index < 0) return undefined;
    const pending = {};
    (pendingQids || []).forEach(x => { pending[String(x)] = true; });
    let last = -1;
    for (let i = ci.index + 1; i < q.length; i++) {
      if (pending[wid(q[i])]) last = i;
    }
    return last >= 0 ? last + 1 : ci.index + 1;
  };
  const mergeCurrent = (q, ci, name) => JSON.stringify({
    ok: true,
    added: false,
    existed: true,
    mergedCurrent: true,
    started: false,
    id: id,
    name: name || (ci.id ? '' : ''),
    qid: ci.wrapper,
    position: ci.index,
    currentIndex: ci.index,
    current: { id: ci.id, state: ci.state },
    queueLen: q.length,
    occurrences: countOf(q),
    anchor: null,
    error: null
  });

  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  let q0 = readQueue();
  let ci0 = curInfo(q0);
  if (ci0.id === id) return mergeCurrent(q0, ci0, '');

  // A copy already waiting after the current song is the same request.
  // Never add a second copy; the caller can move it if it is not at the
  // pending anchor yet.
  const existing0 = findAfter(q0, ci0);
  if (existing0) {
    return JSON.stringify({
      ok: true,
      added: false,
      existed: true,
      alreadyPending: true,
      mergedCurrent: false,
      started: false,
      id: id,
      name: '',
      qid: existing0.qid,
      position: existing0.index,
      currentIndex: ci0.index,
      current: { id: ci0.id, state: ci0.state },
      queueLen: q0.length,
      occurrences: countOf(q0),
      anchor: null,
      error: null
    });
  }

  let response;
  let data;
  let abortTimer = null;
  try {
    const controller = new AbortController();
    abortTimer = setTimeout(() => controller.abort(), 8000);
    response = await fetch('https://music.163.com/api/v3/song/detail?c=' + encodeURIComponent(JSON.stringify([{id:Number(id)}])), {credentials:'include', signal:controller.signal});
    data = await response.json();
  } catch (e) {
    return JSON.stringify({ok:false, error:'detail_fetch_failed', detail:String(e), id:id});
  } finally {
    if (abortTimer) clearTimeout(abortTimer);
  }
  const raw = data && data.songs && data.songs[0];
  if (!raw) {
    return JSON.stringify({ok:false, error:'detail_not_found', status:response && response.status, id:id});
  }
  const name = raw.name || '';
  const track = Object.assign({}, raw, {
    artists: raw.ar || raw.artists || [],
    album: raw.al || raw.album || {},
    duration: raw.dt || raw.duration || 0,
    mvid: raw.mv || raw.mvid || 0,
    alias: raw.alia || raw.alias || []
  });
  try { m.K(track); } catch (e) { }

  // Re-read immediately before the synchronous insert so the anchor is
  // based on the live current index, not a value from an earlier poll.
  const q1 = readQueue();
  const ci1 = curInfo(q1);
  if (ci1.id === id) return mergeCurrent(q1, ci1, name);
  const existing1 = findAfter(q1, ci1);
  if (existing1) {
    return JSON.stringify({
      ok: true,
      added: false,
      existed: true,
      alreadyPending: true,
      mergedCurrent: false,
      started: false,
      id: id,
      name: name,
      qid: existing1.qid,
      position: existing1.index,
      currentIndex: ci1.index,
      current: { id: ci1.id, state: ci1.state },
      queueLen: q1.length,
      occurrences: countOf(q1),
      anchor: null,
      error: null
    });
  }
  const anchor = computeAnchor(q1, ci1);

  const options = {
    fid: 10,
    data: '',
    href: '',
    text: 'BiliNCM',
    nickName: '',
    userId: '',
    fromButton: false
  };
  try {
    if (typeof m.Xn !== 'function') throw new Error('no_Xn');
    m.Xn(track, options, {
      mode: 'normal',
      play: false,
      offset: anchor
    });
  } catch (e) {
    return JSON.stringify({ok:false, error:'queue_update_failed', detail:String(e && (e.stack || e)), id:id});
  }

  await sleep(900);
  const q2 = readQueue();
  const ci2 = curInfo(q2);
  const before = {};
  q1.forEach(x => { before[wid(x)] = true; });
  let addedEntry = null;
  for (let i = 0; i < q2.length; i++) {
    if (idOf(q2[i]) === id && !before[wid(q2[i])]) { addedEntry = { index: i, qid: wid(q2[i]) }; break; }
  }
  if (!addedEntry && anchor !== undefined && anchor >= 0 && anchor < q2.length && idOf(q2[anchor]) === id) {
    addedEntry = { index: anchor, qid: wid(q2[anchor]) };
  }
  if (!addedEntry) {
    const pos = q2.findIndex(x => idOf(x) === id);
    if (pos >= 0) addedEntry = { index: pos, qid: wid(q2[pos]) };
  }
  return JSON.stringify({
    ok: !!addedEntry,
    added: true,
    existed: false,
    alreadyPending: false,
    mergedCurrent: false,
    started: ci2.id === id,
    id: id,
    name: name,
    qid: addedEntry ? addedEntry.qid : '',
    position: addedEntry ? addedEntry.index : -1,
    currentIndex: ci2.index,
    current: { id: ci2.id, state: ci2.state },
    queueLen: q2.length,
    occurrences: countOf(q2),
    anchor: anchor === undefined ? null : anchor,
    currentChanged: (ci1.wrapper !== ci2.wrapper || ci1.start !== ci2.start),
    error: addedEntry ? null : 'queue_not_updated'
  });
})()
'@

$moveExpressionTemplate = @'
(async () => {
  const id = '__SONG_ID__';
  const mode = '__OFFSET_MODE__';
  const explicitOffset = __OFFSET__;
  const pendingQids = __PENDING_QIDS__;
  const m = window.ctl && window.ctl.defPlayer && window.ctl.defPlayer.MF;
  if (!m) return JSON.stringify({ok:false, error:'no_MF', href:location.href});

  const idOf = (x) => {
    if (!x) return '';
    if (x.tid != null) return String(x.tid);
    if (x.id != null) return String(x.id);
    if (x.track && x.track.id != null) return String(x.track.id);
    return '';
  };
  const qidOf = (x) => {
    if (!x) return '';
    if (x.id != null) return String(x.id);
    if (x.tid != null) return String(x.tid);
    if (x.track && x.track.id != null) return String(x.track.id);
    return '';
  };
  const readQueue = () => {
    try { const a = m.V('track_queue'); return Array.isArray(a) ? a.slice() : []; }
    catch (e) { return []; }
  };
  const readPlaying = () => { try { return m.U(); } catch (e) { return null; } };
  const wid = (x) => qidOf(x);
  const curInfo = (q) => {
    const u = readPlaying();
    let curId = '';
    let curWrapper = '';
    let curStart = '';
    let curState = null;
    if (u && u.data && u.data.id != null) {
      curId = String(u.data.id);
      if (u.from) {
        if (u.from.id != null) curWrapper = String(u.from.id);
        if (u.from.startlogtime != null) curStart = String(u.from.startlogtime);
      }
      curState = u.state;
    }
    let index = curWrapper ? q.findIndex(x => wid(x) === curWrapper) : -1;
    if (index < 0 && curId) index = q.findIndex(x => idOf(x) === curId);
    return { id: curId, wrapper: curWrapper, start: curStart, state: curState, index: index };
  };

  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const q0 = readQueue();
  const ci0 = curInfo(q0);
  const occurrences = [];
  for (let i = 0; i < q0.length; i++) {
    if (idOf(q0[i]) === id) occurrences.push(i);
  }
  if (ci0.id === id) {
    return JSON.stringify({
      ok: true,
      moved: false,
      noop: true,
      mergedCurrent: true,
      id: id,
      qid: ci0.wrapper,
      from: ci0.index,
      insertAt: ci0.index,
      anchor: null,
      position: ci0.index,
      currentIndex: ci0.index,
      currentId: ci0.id,
      currentChanged: false,
      queueLen: q0.length,
      error: null
    });
  }
  if (!occurrences.length) {
    return JSON.stringify({ok:false, error:'not_in_queue', id:id, qid:'', from:-1, insertAt:-1, anchor:null, position:-1, currentIndex:ci0.index, currentId:ci0.id, currentChanged:false, queueLen:q0.length});
  }

  // Prefer the first copy after the current song; otherwise use the most
  // recent copy in history. Never choose the current wrapper.
  let chosen = -1;
  for (let i = 0; i < occurrences.length; i++) {
    if (ci0.index >= 0 && occurrences[i] > ci0.index) { chosen = occurrences[i]; break; }
  }
  if (chosen < 0) {
    for (let i = 0; i < occurrences.length; i++) {
      if (ci0.index < 0 || occurrences[i] < ci0.index) chosen = occurrences[i];
    }
  }
  if (chosen < 0) {
    return JSON.stringify({ok:false, error:'only_current', id:id, qid:'', from:-1, insertAt:-1, anchor:null, position:-1, currentIndex:ci0.index, currentId:ci0.id, currentChanged:false, queueLen:q0.length});
  }
  const movedQid = wid(q0[chosen]);

  let anchor = null;
  const alreadyTrackedPending = (pendingQids || []).map(String).indexOf(movedQid) >= 0;
  if (mode === 'pending' && alreadyTrackedPending) {
    // This copy is already a tracked pending d. Its position among the
    // pending d items is the user-visible FIFO order, including manual
    // drags, so never reorder it just because it was asked again.
    anchor = chosen;
  } else if (mode === 'explicit') {
    anchor = Math.max(0, explicitOffset);
  } else if (mode === 'append') {
    anchor = q0.length;
  } else if (mode === 'omit') {
    anchor = q0.length;
  } else {
    if (ci0.index >= 0) {
      const pending = {};
      (pendingQids || []).forEach(x => { pending[String(x)] = true; });
      let last = -1;
      for (let i = ci0.index + 1; i < q0.length; i++) {
        // A move of a song that is already tracked as a pending d must
        // not count itself as the last pending item, otherwise a no-op
        // move would push it behind the later pending requests.
        if (wid(q0[i]) === movedQid) continue;
        if (pending[wid(q0[i])]) last = i;
      }
      anchor = last >= 0 ? last + 1 : ci0.index + 1;
    } else {
      anchor = q0.length;
    }
  }
  if (anchor > q0.length) anchor = q0.length;
  if (anchor < 0) anchor = 0;

  const insertAt = chosen < anchor ? anchor - 1 : anchor;
  if (insertAt === chosen) {
    return JSON.stringify({
      ok: true,
      moved: false,
      noop: true,
      mergedCurrent: false,
      id: id,
      qid: movedQid,
      from: chosen,
      insertAt: insertAt,
      anchor: anchor,
      position: chosen,
      currentIndex: ci0.index,
      currentId: ci0.id,
      currentChanged: false,
      queueLen: q0.length,
      error: null
    });
  }

  const ids = q0.map(x => wid(x));
  if (ids.some(x => !x)) {
    return JSON.stringify({ok:false, error:'empty_qid', id:id, qid:movedQid, from:chosen, insertAt:insertAt, anchor:anchor, position:-1, currentIndex:ci0.index, currentId:ci0.id, currentChanged:false, queueLen:q0.length});
  }
  const moved = ids.splice(chosen, 1)[0];
  const at = Math.max(0, Math.min(insertAt, ids.length));
  ids.splice(at, 0, moved);
  try {
    m.r4('track_queue', ids);
  } catch (e) {
    return JSON.stringify({ok:false, error:'move_failed', detail:String(e && (e.stack || e)), id:id, qid:movedQid, from:chosen, insertAt:at, anchor:anchor, position:-1, currentIndex:ci0.index, currentId:ci0.id, currentChanged:false, queueLen:q0.length});
  }

  await sleep(600);
  const q1 = readQueue();
  const ci1 = curInfo(q1);
  const position = q1.findIndex(x => wid(x) === movedQid);
  return JSON.stringify({
    ok: position >= 0,
    moved: true,
    noop: false,
    mergedCurrent: false,
    id: id,
    qid: movedQid,
    from: chosen,
    insertAt: at,
    anchor: anchor,
    position: position,
    currentIndex: ci1.index,
    currentId: ci1.id,
    currentChanged: (ci0.wrapper !== ci1.wrapper || ci0.start !== ci1.start || ci0.id !== ci1.id),
    queueLen: q1.length,
    error: position >= 0 ? null : 'moved_item_missing'
  });
})()
'@

$diagnosticsExpression = @'
(() => {
  const st = (() => { try { return window._reduxStore ? window._reduxStore.getState() : null; } catch (e) { return null; } })();
  const m = window.ctl && window.ctl.defPlayer && window.ctl.defPlayer.MF;
  const shape = (o, level) => {
    if (o === null || o === undefined) return o;
    if (level > 2) return 'object';
    if (typeof o !== 'object') {
      if (typeof o === 'string' && o.length > 120) return o.slice(0, 120) + '...';
      return o;
    }
    if (Array.isArray(o)) {
      return { __array: o.length, sample: o.slice(0, 2).map(x => shape(x, level + 1)) };
    }
    const out = {};
    Object.keys(o).slice(0, 30).forEach(k => { out[k] = shape(o[k], level + 1); });
    return out;
  };
  const read = (k) => { try { return m && typeof m.V === 'function' ? m.V(k) : null; } catch (e) { return String(e); } };
  const queue = read('track_queue');
  let currentRaw = null;
  try { currentRaw = m && typeof m.U === 'function' ? m.U() : null; } catch (e) { currentRaw = String(e); }
  const keys = m ? Object.keys(m) : [];
  const interesting = keys.filter(k => /queue|Queue|next|Next|add|Add|insert|Insert|move|Move|play|Play|remove|Remove|list|List|^[VUKX]$/.test(k)).slice(0, 60);
  const sources = {};
  interesting.forEach(k => {
    try {
      if (typeof m[k] === 'function') {
        const s = String(m[k]);
        sources[k] = s.length > 700 ? s.slice(0, 700) : s;
      }
    } catch (e) { }
  });
  const cpl = st && st.playingList && Array.isArray(st.playingList.curPlayingList) ? st.playingList.curPlayingList : null;
  return JSON.stringify({
    ok: !!m,
    href: location.href,
    timeOrigin: performance.timeOrigin,
    mfKeys: keys.slice(0, 300).map(k => k + ':' + typeof m[k]),
    sources: sources,
    queueType: Array.isArray(queue) ? 'array' : typeof queue,
    queueLen: Array.isArray(queue) ? queue.length : null,
    queueFirst: Array.isArray(queue) && queue.length ? shape(queue[0], 0) : null,
    currentRaw: shape(currentRaw, 0),
    reduxPlaying: shape(st && st.playing, 0),
    playingListLen: cpl ? cpl.length : null,
    playingListFirst: cpl && cpl.length ? shape(cpl[0], 0) : null
  });
})()
'@

function Get-NcmDiagnostics {
    $targets = @(Get-CdpPageTargets)
    foreach ($target in $targets) {
        try {
            $response = Invoke-CdpEvaluate -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $diagnosticsExpression -TimeoutSeconds 10 -AwaitPromise $false
            $obj = Get-EvaluateJson -Response $response
            if ($obj -and $obj.ok) { return $obj }
        } catch { }
    }
    return $null
}

function Invoke-NcmBridge {
    $targets = @(Get-CdpPageTargets)
    foreach ($target in $targets) {
        try {
            $response = Invoke-CdpEvaluate -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $bridgeExpression -TimeoutSeconds 15 -AwaitPromise $false
            $obj = Get-EvaluateJson -Response $response
            if ($obj -and $obj.hasReactRoot) {
                return [pscustomobject]@{ Ok = [bool]$obj.ok; HasStore = [bool]$obj.hasStore; Detail = $obj }
            }
        } catch { }
    }
    return $null
}

function Get-NcmState {
    $targets = @(Get-CdpPageTargets)
    foreach ($target in $targets) {
        try {
            $response = Invoke-CdpEvaluate -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $stateExpression -TimeoutSeconds 10 -AwaitPromise $false
            $obj = Get-EvaluateJson -Response $response
            if ($obj -and $obj.ok) {
                $currentIndex = -1
                if ($null -ne $obj.currentIndex) {
                    try { $currentIndex = [int]$obj.currentIndex } catch { $currentIndex = -1 }
                }
                return [pscustomobject]@{
                    Ok           = $true
                    Page         = [string]$obj.page
                    Current      = $obj.current
                    CurrentIndex = $currentIndex
                    CurrentWrapper = [string]$obj.currentWrapper
                    CurrentMatchedBy = [string]$obj.currentMatchedBy
                    Queue        = @($obj.queue)
                    PlayingList  = @($obj.playingList)
                    QueueLen     = [int]$obj.queueLen
                }
            }
        } catch { }
    }
    return $null
}

function ConvertTo-JsStringArray {
    param([string[]]$Items)
    $safe = New-Object 'System.Collections.Generic.List[string]'
    if ($Items) {
        foreach ($item in $Items) {
            $text = [string]$item
            if ($text -match '^[0-9_]+$') { $safe.Add($text) }
        }
    }
    if ($safe.Count -eq 0) { return '[]' }
    return ('[' + (($safe | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']')
}

function Get-OffsetMode {
    param([int]$Offset, [string]$Mode)
    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        if ($Mode -in @('pending', 'append', 'omit', 'explicit')) { return $Mode }
    }
    if ($Offset -eq -2) { return 'omit' }
    if ($Offset -lt 0) { return 'append' }
    return 'explicit'
}

function Get-PendingQidList {
    param([hashtable]$Known, [object]$Ncm)
    $out = New-Object 'System.Collections.Generic.List[string]'
    if (-not $Known -or -not $Ncm) { return @() }
    $currentIndex = -1
    if ($null -ne $Ncm.CurrentIndex) { $currentIndex = [int]$Ncm.CurrentIndex }
    $queue = @($Ncm.Queue)
    $indices = @{}
    for ($i = 0; $i -lt $queue.Count; $i++) {
        $qid = [string]$queue[$i].qid
        if ($qid) { $indices[$qid] = $i }
    }
    foreach ($k in @($Known.Values)) {
        if (-not ($k.IsD -and $k.State -eq 'Pending')) { continue }
        $qid = [string]$k.PendingQid
        if ([string]::IsNullOrWhiteSpace($qid)) { continue }
        if (-not $indices.ContainsKey($qid)) { continue }
        if ($currentIndex -ge 0 -and [int]$indices[$qid] -le $currentIndex) { continue }
        if (-not $out.Contains($qid)) { $out.Add($qid) }
    }
    return @($out)
}

function Invoke-NcmAddSong {
    param(
        [string]$SongId,
        [int]$Offset = -1,
        [string]$Mode = '',
        [string[]]$PendingQids = @()
    )

    if ($SongId -notmatch '^\d+$') {
        return [pscustomobject]@{ Ok = $false; Error = 'invalid_song_id'; Id = $SongId }
    }

    $offsetMode = Get-OffsetMode -Offset $Offset -Mode $Mode
    $offsetJs = if ($Offset -lt 0) { '0' } else { [string]$Offset }
    $pendingJs = ConvertTo-JsStringArray -Items $PendingQids
    $expr = $addExpressionTemplate.Replace('__SONG_ID__', $SongId).Replace('__OFFSET_MODE__', $offsetMode).Replace('__PENDING_QIDS__', $pendingJs).Replace('__OFFSET__', $offsetJs)
    $targets = @(Get-CdpPageTargets)
    if ($targets.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = 'no_cdp_page'; Id = $SongId }
    }

    $lastError = 'no_result'
    foreach ($target in $targets) {
        try {
            $response = Invoke-CdpEvaluate -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $expr -TimeoutSeconds 35 -AwaitPromise $true
            $obj = Get-EvaluateJson -Response $response
            if ($obj) {
                $anchor = $null
                if ($null -ne $obj.anchor) {
                    try { $anchor = [int]$obj.anchor } catch { $anchor = $null }
                }
                $currentIndex = -1
                if ($null -ne $obj.currentIndex) {
                    try { $currentIndex = [int]$obj.currentIndex } catch { $currentIndex = -1 }
                }
                return [pscustomobject]@{
                    Ok             = [bool]$obj.ok
                    Added          = [bool]$obj.added
                    Existed        = [bool]$obj.existed
                    AlreadyPending = [bool]$obj.alreadyPending
                    MergedCurrent  = [bool]$obj.mergedCurrent
                    Started        = [bool]$obj.started
                    Id             = [string]$obj.id
                    Name           = [string]$obj.name
                    Qid            = [string]$obj.qid
                    Current        = $obj.current
                    QueueLen       = [int]$obj.queueLen
                    Position       = [int]$obj.position
                    CurrentIndex   = $currentIndex
                    Occurrences    = [int]$obj.occurrences
                    Anchor         = $anchor
                    CurrentChanged = [bool]$obj.currentChanged
                    Mode           = $offsetMode
                    Error          = [string]$obj.error
                }
            }
            $lastError = 'empty_result'
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ Ok = $false; Error = $lastError; Id = $SongId; Mode = $offsetMode }
}

function Add-NcmSong {
    param(
        [string]$SongId,
        [string]$Source = 'unknown',
        [int]$Offset = -1,
        [string]$Mode = '',
        [string[]]$PendingQids = @()
    )

    $result = Invoke-NcmAddSong -SongId $SongId -Offset $Offset -Mode $Mode -PendingQids $PendingQids
    $offsetText = Get-OffsetMode -Offset $Offset -Mode $Mode
    if ($result.Ok) {
        $name = if ($result.Name) { $result.Name } else { '' }
        $currentText = 'none'
        if ($result.Current -and $null -ne $result.Current.id) {
            $currentText = [string]$result.Current.id
        }
        Write-CompanionLog ("{0}: id={1} name={2} added={3} existed={4} mode={5} anchor={6} pos={7} qid={8} dup={9} queue={10} current={11}" -f `
            $Source, $SongId, $name, $result.Added, $result.Existed, $offsetText, $result.Anchor, $result.Position, $result.Qid, $result.Occurrences, $result.QueueLen, $currentText) 'OK'
    } else {
        Write-CompanionLog ("{0}: id={1} mode={2} offset={3} failed: {4}" -f $Source, $SongId, $offsetText, $Offset, $result.Error) 'WARN'
    }
    return $result
}

function Move-NcmQueueItem {
    param(
        [string]$SongId,
        [int]$Offset = -1,
        [string]$Mode = 'pending',
        [string[]]$PendingQids = @()
    )

    if ($SongId -notmatch '^\d+$') {
        return [pscustomobject]@{ Ok = $false; Error = 'invalid_song_id'; Id = $SongId }
    }

    $offsetMode = Get-OffsetMode -Offset $Offset -Mode $Mode
    $offsetJs = if ($Offset -lt 0) { '0' } else { [string]$Offset }
    $pendingJs = ConvertTo-JsStringArray -Items $PendingQids
    $expr = $moveExpressionTemplate.Replace('__SONG_ID__', $SongId).Replace('__OFFSET_MODE__', $offsetMode).Replace('__PENDING_QIDS__', $pendingJs).Replace('__OFFSET__', $offsetJs)
    $targets = @(Get-CdpPageTargets)
    if ($targets.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = 'no_cdp_page'; Id = $SongId; Mode = $offsetMode }
    }

    $lastError = 'no_result'
    foreach ($target in $targets) {
        try {
            $response = Invoke-CdpEvaluate -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $expr -TimeoutSeconds 25 -AwaitPromise $true
            $obj = Get-EvaluateJson -Response $response
            if ($obj) {
                $currentIndex = -1
                if ($null -ne $obj.currentIndex) {
                    try { $currentIndex = [int]$obj.currentIndex } catch { $currentIndex = -1 }
                }
                $anchor = $null
                if ($null -ne $obj.anchor) {
                    try { $anchor = [int]$obj.anchor } catch { $anchor = $null }
                }
                return [pscustomobject]@{
                    Ok             = [bool]$obj.ok
                    Moved          = [bool]$obj.moved
                    Noop           = [bool]$obj.noop
                    MergedCurrent  = [bool]$obj.mergedCurrent
                    Id             = [string]$obj.id
                    Qid            = [string]$obj.qid
                    From           = [int]$obj.from
                    InsertAt       = [int]$obj.insertAt
                    Anchor         = $anchor
                    Position       = [int]$obj.position
                    CurrentIndex   = $currentIndex
                    CurrentId      = [string]$obj.currentId
                    CurrentChanged = [bool]$obj.currentChanged
                    QueueLen       = [int]$obj.queueLen
                    Mode           = $offsetMode
                    Error          = [string]$obj.error
                }
            }
            $lastError = 'empty_result'
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ Ok = $false; Error = $lastError; Id = $SongId; Mode = $offsetMode }
}

function Get-BotData {
    try {
        $text = Invoke-Utf8Http -Url ($BotBaseUrl + '/data') -TimeoutSec 3
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Set-BotAutoPlayPaused {
    try {
        Invoke-WebRequest -Uri ($BotBaseUrl + '/api/state/toggle_play') -Method POST -UseBasicParsing -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-BotQueueInfo {
    param([object]$BotData)

    $items = @()
    if ($BotData -and $BotData.queue) { $items = @($BotData.queue) }

    $counts = @{}
    $byId = @{}
    $order = New-Object 'System.Collections.Generic.List[string]'

    foreach ($item in $items) {
        $id = [string]$item.Id
        if ($id -notmatch '^\d+$') { continue }
        if ($counts.ContainsKey($id)) {
            $counts[$id] = [int]$counts[$id] + 1
        } else {
            $counts[$id] = 1
            $order.Add($id)
        }
        if (-not $byId.ContainsKey($id)) {
            $byId[$id] = [pscustomobject]@{
                Id        = $id
                Name      = [string]$item.SongName
                Artists   = [string]$item.ArtistName
                OrderedBy = [string]$item.OrderedBy
            }
        }
    }

    return [pscustomobject]@{
        RawOrder = @($order)
        Counts   = $counts
        ById     = $byId
        Total    = $items.Count
    }
}

function Get-PendingAnchor {
    param(
        [object[]]$Queue,
        [hashtable]$Known,
        [int]$CurrentIndex = -1
    )
    if ($CurrentIndex -lt 0) { return -2 }
    $items = @($Queue)
    $last = -1
    for ($i = $CurrentIndex + 1; $i -lt $items.Count; $i++) {
        $qid = [string]$items[$i].qid
        $id = [string]$items[$i].id
        if (-not $Known.ContainsKey($id)) { continue }
        $k = $Known[$id]
        if (-not ($k.IsD -and $k.State -eq 'Pending')) { continue }
        $pendingQid = [string]$k.PendingQid
        if (-not [string]::IsNullOrWhiteSpace($pendingQid) -and $pendingQid -ne $qid) { continue }
        $last = $i
    }
    if ($last -ge 0) { return ($last + 1) }
    return ($CurrentIndex + 1)
}

function Add-BacklogId {
    param(
        [System.Collections.Generic.List[string]]$Backlog,
        [string]$Id
    )
    if (-not $Backlog.Contains($Id)) { $Backlog.Add($Id) }
}

function Remove-BacklogId {
    param(
        [System.Collections.Generic.List[string]]$Backlog,
        [string]$Id
    )
    while ($Backlog.Contains($Id)) { [void]$Backlog.Remove($Id) }
}

function Sort-BacklogBySeq {
    param(
        [System.Collections.Generic.List[string]]$Backlog,
        [hashtable]$Known
    )
    if ($Backlog.Count -le 1) { return }
    $ordered = @($Backlog | Sort-Object {
        $sid = [string]$_
        if ($Known.ContainsKey($sid)) { [int]$Known[$sid].Seq } else { [int]::MaxValue }
    })
    $Backlog.Clear()
    foreach ($item in $ordered) {
        $sid = [string]$item
        if (-not $Backlog.Contains($sid)) { $Backlog.Add($sid) }
    }
}

function Write-OverlayState {
    param([hashtable]$State)
    try {
        $json = $State | ConvertTo-Json -Depth 8 -Compress
        $tmp = $OverlayStateFile + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $OverlayStateFile) {
            try {
                [IO.File]::Replace($tmp, $OverlayStateFile, [NullString]::Value)
            } catch {
                Move-Item -LiteralPath $tmp -Destination $OverlayStateFile -Force
            }
        } else {
            Move-Item -LiteralPath $tmp -Destination $OverlayStateFile -Force
        }
    } catch {
        Write-CompanionLog ('overlay state write failed: ' + $_.Exception.Message) 'WARN'
    }
}

function New-OverlayState {
    param(
        [object]$Ncm,
        [bool]$NcmOk,
        [object]$BotData,
        [hashtable]$Known,
        [string]$CurrentId,
        [string]$Alert,
        [bool]$BotAutoPlay
    )

    $currentOut = $null
    $pendingOut = @()

    if ($NcmOk -and $Ncm) {
        $c = $Ncm.Current
        if ($c -and $c.id) {
            $cid = [string]$c.id
            $cname = [string]$c.name
            $cart = [string]$c.artists
            $badge = 'manual'
            $orderer = ''
            if ($Known.ContainsKey($cid)) {
                $k = $Known[$cid]
                if ($k.IsD -and ($k.State -eq 'Pending' -or $k.State -eq 'Playing')) {
                    $badge = 'd'
                    $orderer = [string]$k.OrderedBy
                }
                if ([string]::IsNullOrWhiteSpace($cname)) { $cname = [string]$k.Name }
                if ([string]::IsNullOrWhiteSpace($cart)) { $cart = [string]$k.Artists }
            }
            $currentOut = @{
                id      = $cid
                name    = $cname
                artists = $cart
                badge   = $badge
                orderer = $orderer
            }
        }

        $seen = @{}
        $currentIndex = -1
        if ($null -ne $Ncm.CurrentIndex) { $currentIndex = [int]$Ncm.CurrentIndex }
        $queue = @($Ncm.Queue)
        for ($i = 0; $i -lt $queue.Count; $i++) {
            $q = $queue[$i]
            $qid = [string]$q.qid
            if ([string]::IsNullOrWhiteSpace($qid)) { continue }
            if ($seen.ContainsKey($qid)) { continue }
            $seen[$qid] = $true
            $tid = [string]$q.id
            if ($currentIndex -ge 0) {
                if ($i -le $currentIndex) { continue }
            } elseif (-not [string]::IsNullOrWhiteSpace($CurrentId) -and $tid -eq $CurrentId) {
                continue
            }
            if (-not $Known.ContainsKey($tid)) { continue }
            $k = $Known[$tid]
            if (-not ($k.IsD -and $k.State -eq 'Pending')) { continue }

            # Only the exact queue wrapper that belongs to this pending d
            # may be shown. A manual copy of the same song elsewhere in
            # the list must not turn into a pending row.
            $pendingQid = [string]$k.PendingQid
            if (-not [string]::IsNullOrWhiteSpace($pendingQid) -and $pendingQid -ne $qid) { continue }

            $qname = [string]$q.name
            $qart = [string]$q.artists
            if ([string]::IsNullOrWhiteSpace($qname)) { $qname = [string]$k.Name }
            if ([string]::IsNullOrWhiteSpace($qart)) { $qart = [string]$k.Artists }
            $pendingOut += @{
                id      = $tid
                name    = $qname
                artists = $qart
                orderer = [string]$k.OrderedBy
            }
        }
    }

    $accepting = $true
    if ($BotData) {
        $acceptProp = $BotData.PSObject.Properties['accepting']
        if ($acceptProp -and $acceptProp.Value -eq $false) { $accepting = $false }
    }

    return @{
        ts          = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        bot         = [bool]($null -ne $BotData)
        ncm         = [bool]$NcmOk
        accepting   = [bool]$accepting
        botAutoPlay = [bool]$BotAutoPlay
        alert       = [string]$Alert
        current     = $currentOut
        pending     = @($pendingOut)
        pendingCount= [int]@($pendingOut).Count
        updated     = (Get-Date -Format 'HH:mm:ss')
    }
}

# ----------------------------------------------------------------------
# Single instance
# ----------------------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\BiliNCM-Companion')
$haveMutex = $false
$runExclusive = (-not $ProbeNcm) -and [string]::IsNullOrWhiteSpace($TestSongId)
try {
    if ($runExclusive) {
        try { $haveMutex = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
        if (-not $haveMutex) { exit 0 }

        try {
            if (Test-Path -LiteralPath $LogFile) {
                $item = Get-Item -LiteralPath $LogFile
                if ($item.Length -gt 2097152) {
                    Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.1') -Force
                }
            }
        } catch { }
    }

    Write-CompanionLog 'companion starting (overlay/priority mode)'
    Write-CompanionLog ("root={0} cdp={1} bot={2} pollMs={3}" -f $Root, $CdpPort, $BotPort, $PollMilliseconds)

    # Bridge injection helps the bot's radar initialize against #portal_root.
    $bridge = $null
    $bridgeWaitDeadline = (Get-Date).AddSeconds(30)
    do {
        $bridge = Invoke-NcmBridge
        if ($bridge) { break }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $bridgeWaitDeadline)
    if ($bridge) {
        Write-CompanionLog ("bridge: reactRoot={0} store={1}" -f $bridge.Detail.hasReactRoot, $bridge.HasStore) 'OK'
    } else {
        Write-CompanionLog 'bridge: NCM CDP page not ready yet; will retry' 'WARN'
    }

    if ($ProbeNcm) {
        $probe = Get-NcmState
        if ($probe) {
            $diagnostics = Get-NcmDiagnostics
            if ($diagnostics) {
                try { $probe | Add-Member -NotePropertyName Diagnostics -NotePropertyValue $diagnostics -Force } catch { }
            }
            $probeFile = Join-Path $Root 'probe-ncm.json'
            try {
                $probeJson = $probe | ConvertTo-Json -Depth 10
                [IO.File]::WriteAllText($probeFile, $probeJson, (New-Object Text.UTF8Encoding($false)))
            } catch { }
            Write-CompanionLog ("probe: page={0} current={1} queue={2}" -f $probe.Page, $(if ($probe.Current) { $probe.Current.id } else { 'none' }), $probe.QueueLen) 'OK'
            exit 0
        }
        Write-CompanionLog 'probe: NCM state unavailable' 'WARN'
        exit 2
    }

    if (-not [string]::IsNullOrWhiteSpace($TestSongId)) {
        $testResult = Add-NcmSong -SongId $TestSongId -Source 'test' -Offset $TestOffset
        if ($testResult.Ok) { exit 0 }
        exit 2
    }

    $known = @{}
    $rawCounts = @{}
    $backlog = New-Object 'System.Collections.Generic.List[string]'
    $sessionReady = $false
    $lastBotPid = 0
    $lastNcmPage = ''
    $lastNcmRestartAt = [DateTime]::MinValue
    $ncmRestartHandled = $true
    $lastPauseAt = [DateTime]::MinValue
    $alert = ''
    $alertLogged = $false
    $lastBotSeen = Get-Date
    $requestSeq = 0

    while ($true) {
        try {
            $botProcs = @(Get-Process -Name 'BiliNCM-Bot' -ErrorAction SilentlyContinue)
            if ($botProcs.Count -eq 0) {
                if (((Get-Date) - $lastBotSeen).TotalSeconds -ge $IdleExitSeconds) {
                    Write-CompanionLog 'bot absent; companion exiting'
                    break
                }
                $state = New-OverlayState -Ncm $null -NcmOk $false -BotData $null -Known $known -CurrentId '' -Alert '' -BotAutoPlay $false
                Write-OverlayState -State $state
                Start-Sleep -Milliseconds $PollMilliseconds
                continue
            }
            $lastBotSeen = Get-Date

            $botPid = [int]$botProcs[0].Id
            if ($lastBotPid -ne 0 -and $botPid -ne $lastBotPid) {
                Write-CompanionLog ("bot restarted (pid {0} -> {1}); new session, pending d reset" -f $lastBotPid, $botPid) 'WARN'
                $known.Clear()
                $rawCounts.Clear()
                $backlog.Clear()
                $sessionReady = $false
                $lastNcmPage = ''
                $lastNcmRestartAt = [DateTime]::MinValue
                $ncmRestartHandled = $true
                $requestSeq = 0
            }
            $lastBotPid = $botPid

            $botData = Get-BotData
            if ($null -eq $botData) {
                Start-Sleep -Milliseconds $PollMilliseconds
                continue
            }

            # ---- keep the bot's own auto-play disabled -------------------
            $playingProp = $botData.PSObject.Properties['playing']
            $botAutoPlay = $false
            if ($playingProp) { $botAutoPlay = [bool]$playingProp.Value }
            if ($botAutoPlay) {
                $botCurrent = $null
                $curProp = $botData.PSObject.Properties['current']
                if ($curProp) { $botCurrent = $curProp.Value }
                if ($null -eq $botCurrent) {
                    if (((Get-Date) - $lastPauseAt).TotalSeconds -ge 3) {
                        $lastPauseAt = Get-Date
                        if (Set-BotAutoPlayPaused) {
                            Write-CompanionLog 'bot auto-play paused (overlay mode requires it)' 'OK'
                            $alert = ''
                            $alertLogged = $false
                        } else {
                            Write-CompanionLog 'bot auto-play pause request failed' 'WARN'
                        }
                    }
                } else {
                    $alert = 'bot_autoplay_on'
                    if (-not $alertLogged) {
                        Write-CompanionLog 'bot auto-play is ON with an adopted current song; not pausing to avoid a cut' 'WARN'
                        $alertLogged = $true
                    }
                }
            } else {
                $alert = ''
                $alertLogged = $false
            }

            # ---- read NCM state ----------------------------------------
            $ncm = Get-NcmState
            $ncmOk = ($null -ne $ncm)

            $ncmPage = ''
            $currentId = ''
            $currentIndex = -1
            $currentWrapper = ''
            $ncmQueue = @()
            $qidIndex = @{}
            $tidIndices = @{}
            $ncmRestartPending = $false
            $restartBlocked = $false

            if ($ncmOk) {
                $ncmPage = [string]$ncm.Page
                if ($ncm.Current -and $ncm.Current.id) { $currentId = [string]$ncm.Current.id }
                if ($null -ne $ncm.CurrentIndex) { $currentIndex = [int]$ncm.CurrentIndex }
                $currentWrapper = [string]$ncm.CurrentWrapper
                $ncmQueue = @($ncm.Queue)

                for ($i = 0; $i -lt $ncmQueue.Count; $i++) {
                    $q = $ncmQueue[$i]
                    $qid = [string]$q.qid
                    if (-not [string]::IsNullOrWhiteSpace($qid) -and -not $qidIndex.ContainsKey($qid)) {
                        $qidIndex[$qid] = $i
                    }
                    $tid = [string]$q.id
                    if (-not [string]::IsNullOrWhiteSpace($tid)) {
                        if (-not $tidIndices.ContainsKey($tid)) {
                            $tidIndices[$tid] = New-Object 'System.Collections.Generic.List[int]'
                        }
                        $tidIndices[$tid].Add($i)
                    }
                }

                if ($lastNcmPage -ne '' -and $ncmPage -ne $lastNcmPage) {
                    Write-CompanionLog 'NCM page changed (restart); reconciling pending d against the restored queue' 'WARN'
                    $lastNcmRestartAt = Get-Date
                    $ncmRestartHandled = $false
                }
                $lastNcmPage = $ncmPage
                $ncmRestartPending = -not $ncmRestartHandled
            }

            # ---- bot queue delta ----------------------------------------
            $queueInfo = Get-BotQueueInfo -BotData $botData
            if (-not $sessionReady) {
                foreach ($id in @($queueInfo.RawOrder)) {
                    $meta = $queueInfo.ById[$id]
                    $known[$id] = @{
                        Id            = $id
                        Name          = if ($meta) { [string]$meta.Name } else { '' }
                        Artists       = if ($meta) { [string]$meta.Artists } else { '' }
                        OrderedBy     = if ($meta) { [string]$meta.OrderedBy } else { '' }
                        IsD           = $false
                        State         = 'Legacy'
                        PendingQid    = ''
                        Seq           = 0
                        Absent        = 0
                        BotAbsent     = 0
                        RetryAt       = [DateTime]::MinValue
                        ReRequested   = $false
                    }
                }
                $rawCounts = @{}
                foreach ($key in $queueInfo.Counts.Keys) { $rawCounts[$key] = [int]$queueInfo.Counts[$key] }
                $sessionReady = $true
                Write-CompanionLog ("session baseline: {0} existing bot queue entries treated as s/q" -f $known.Count) 'OK'
            } else {
                foreach ($id in @($queueInfo.RawOrder)) {
                    $prev = 0
                    if ($rawCounts.ContainsKey($id)) { $prev = [int]$rawCounts[$id] }
                    $nowCount = [int]$queueInfo.Counts[$id]
                    if ($nowCount -le $prev) { continue }

                    $meta = $queueInfo.ById[$id]
                    if (-not $known.ContainsKey($id)) {
                        $requestSeq++
                        $known[$id] = @{
                            Id            = $id
                            Name          = if ($meta) { [string]$meta.Name } else { '' }
                            Artists       = if ($meta) { [string]$meta.Artists } else { '' }
                            OrderedBy     = if ($meta) { [string]$meta.OrderedBy } else { '' }
                            IsD           = $true
                            State         = 'New'
                            PendingQid    = ''
                            Seq           = $requestSeq
                            Absent        = 0
                            BotAbsent     = 0
                            RetryAt       = [DateTime]::MinValue
                            ReRequested   = $false
                        }
                        Add-BacklogId -Backlog $backlog -Id $id
                        Write-CompanionLog ("request: id={0} name={1} by={2}" -f $id, $(if ($meta) { $meta.Name } else { '' }), $(if ($meta) { $meta.OrderedBy } else { '' })) 'OK'
                    } else {
                        $k = $known[$id]
                        if ($id -eq $currentId) {
                            $k.ReRequested = $false
                            Write-CompanionLog ("request: id={0} merge (currently playing)" -f $id) 'OK'
                        } elseif ($k.State -eq 'Pending' -or $k.State -eq 'Playing') {
                            $k.ReRequested = $true
                            Write-CompanionLog ("request: id={0} merge (already pending/playing)" -f $id) 'OK'
                        } elseif ($k.State -eq 'New' -or $k.State -eq 'Upgrade') {
                            Write-CompanionLog ("request: id={0} merge (already queued for upgrade)" -f $id) 'OK'
                        } else {
                            $requestSeq++
                            $k.IsD = $true
                            $k.State = 'Upgrade'
                            $k.PendingQid = ''
                            $k.Absent = 0
                            $k.RetryAt = [DateTime]::MinValue
                            $k.ReRequested = $false
                            $k.Seq = $requestSeq
                            Add-BacklogId -Backlog $backlog -Id $id
                            Write-CompanionLog ("request: id={0} re-request -> move/upgrade to d" -f $id) 'OK'
                        }
                    }
                }

                # A request deleted from the bot queue before it reached NCM
                # must be cancelled too, otherwise the companion would add
                # a song the user already withdrew.
                foreach ($k in @($known.Values)) {
                    if (-not ($k.State -eq 'New' -or $k.State -eq 'Upgrade')) { continue }
                    $nowCount = 0
                    if ($queueInfo.Counts.ContainsKey([string]$k.Id)) { $nowCount = [int]$queueInfo.Counts[[string]$k.Id] }
                    if ($nowCount -le 0) {
                        Remove-BacklogId -Backlog $backlog -Id ([string]$k.Id)
                        $k.State = 'Done'
                        $k.ReRequested = $false
                        Write-CompanionLog ("request cancelled before queue add: id={0} name={1}" -f $k.Id, $k.Name) 'OK'
                    }
                }

                # A pending d withdrawn from the bot queue stops being a d.
                # The companion does not delete the NCM copy itself: if the
                # bot's own delete removed it, reconciliation sees that on
                # the next poll; otherwise the copy stays as a normal song.
                foreach ($k in @($known.Values)) {
                    if (-not ($k.IsD -and $k.State -eq 'Pending')) { continue }
                    if ($currentId -and $k.Id -eq $currentId) { $k.BotAbsent = 0; continue }
                    $nowCount = 0
                    if ($queueInfo.Counts.ContainsKey([string]$k.Id)) { $nowCount = [int]$queueInfo.Counts[[string]$k.Id] }
                    if ($nowCount -gt 0) {
                        $k.BotAbsent = 0
                        continue
                    }
                    $k.BotAbsent = [int]$k.BotAbsent + 1
                    if ($k.BotAbsent -ge 2) {
                        Remove-BacklogId -Backlog $backlog -Id ([string]$k.Id)
                        $k.State = 'Done'
                        $k.PendingQid = ''
                        $k.Absent = 0
                        $k.ReRequested = $false
                        Write-CompanionLog ("pending d cancelled from bot queue: id={0} name={1}" -f $k.Id, $k.Name) 'OK'
                    }
                }

                $rawCounts = @{}
                foreach ($key in $queueInfo.Counts.Keys) { $rawCounts[$key] = [int]$queueInfo.Counts[$key] }
                Sort-BacklogBySeq -Backlog $backlog -Known $known
            }

            # ---- reconcile d state against the real NCM queue ----------
            # Everything is relative to currentIndex: the queue contains
            # history, the current song, and the upcoming songs.
            if ($ncmOk) {
                $skipAbsence = $ncmRestartPending
                foreach ($k in @($known.Values)) {
                    if (-not $k.IsD) { continue }

                    if ($k.State -eq 'Pending') {
                        $pq = [string]$k.PendingQid
                        $pqIdx = -1
                        if (-not [string]::IsNullOrWhiteSpace($pq) -and $qidIndex.ContainsKey($pq)) {
                            $pqIdx = [int]$qidIndex[$pq]
                        }
                        if ($pqIdx -ge 0) {
                            $k.Absent = 0
                            if ($currentId -and $k.Id -eq $currentId) {
                                $k.State = 'Playing'
                                Write-CompanionLog ("playing: id={0} name={1} (pending d consumed)" -f $k.Id, $k.Name) 'OK'
                            } elseif ($currentIndex -ge 0 -and $pqIdx -eq $currentIndex) {
                                $k.State = 'Playing'
                                Write-CompanionLog ("playing: id={0} name={1} (pending d consumed)" -f $k.Id, $k.Name) 'OK'
                            } elseif ($currentIndex -ge 0 -and $pqIdx -lt $currentIndex) {
                                $k.State = 'Done'
                                Write-CompanionLog ("played: id={0} name={1} (d is now s-level, stays in list)" -f $k.Id, $k.Name) 'OK'
                            }
                            continue
                        }

                        if ($currentId -and $k.Id -eq $currentId) {
                            $k.State = 'Playing'
                            $k.Absent = 0
                            if (-not [string]::IsNullOrWhiteSpace($currentWrapper)) { $k.PendingQid = $currentWrapper }
                            Write-CompanionLog ("playing: id={0} name={1} (pending d consumed)" -f $k.Id, $k.Name) 'OK'
                            continue
                        }

                        $indices = @()
                        if ($tidIndices.ContainsKey([string]$k.Id)) { $indices = @($tidIndices[[string]$k.Id]) }
                        if ($currentIndex -ge 0) {
                            $after = @($indices | Where-Object { $_ -gt $currentIndex })
                            if ($after.Count -gt 0) {
                                $newIdx = [int]$after[0]
                                $k.PendingQid = [string]$ncmQueue[$newIdx].qid
                                $k.Absent = 0
                                Write-CompanionLog ("pending d wrapper changed; tracking new occurrence: id={0} pos={1}" -f $k.Id, $newIdx) 'WARN'
                                continue
                            }
                            $before = @($indices | Where-Object { $_ -lt $currentIndex })
                            if ($before.Count -gt 0) {
                                $k.State = 'Done'
                                $k.Absent = 0
                                Write-CompanionLog ("played: id={0} name={1} (d is now s-level, stays in list)" -f $k.Id, $k.Name) 'OK'
                                continue
                            }
                        }

                        if ($skipAbsence) { continue }
                        $k.Absent = [int]$k.Absent + 1
                        if ($k.Absent -ge 3) {
                            $k.State = 'Done'
                            Write-CompanionLog ("pending d left NCM queue without playing (cancelled/removed): id={0} name={1}" -f $k.Id, $k.Name) 'WARN'
                        }
                    } elseif ($k.State -eq 'Playing') {
                        if ($currentId -and $k.Id -eq $currentId) {
                            $k.Absent = 0
                            continue
                        }
                        $indices = @()
                        if ($tidIndices.ContainsKey([string]$k.Id)) { $indices = @($tidIndices[[string]$k.Id]) }
                        $played = $false
                        if ($currentIndex -ge 0) {
                            $played = (@($indices | Where-Object { $_ -lt $currentIndex }).Count -gt 0)
                        }
                        if ($played) {
                            $k.State = 'Done'
                            $k.Absent = 0
                            Write-CompanionLog ("played: id={0} name={1} (d is now s-level, stays in list)" -f $k.Id, $k.Name) 'OK'
                            continue
                        }
                        $k.Absent = [int]$k.Absent + 1
                        if ($k.Absent -ge 2) {
                            $k.State = 'Done'
                            Write-CompanionLog ("played: id={0} name={1} (left current)" -f $k.Id, $k.Name) 'OK'
                        }
                    } elseif ($k.State -eq 'New' -or $k.State -eq 'Upgrade') {
                        if ($currentId -and $k.Id -eq $currentId) {
                            $k.State = 'Playing'
                            $k.Absent = 0
                            Write-CompanionLog ("request: id={0} merge (currently playing)" -f $k.Id) 'OK'
                        }
                    }
                }
            }

            # A re-request that arrived while an old d was finishing is
            # upgraded after reconciliation, so it never gets lost.
            foreach ($k in @($known.Values)) {
                if (-not $k.IsD) { continue }
                if ($k.State -eq 'Done' -and $k.ReRequested) {
                    $requestSeq++
                    $k.State = 'Upgrade'
                    $k.PendingQid = ''
                    $k.Absent = 0
                    $k.RetryAt = [DateTime]::MinValue
                    $k.ReRequested = $false
                    $k.Seq = $requestSeq
                    Add-BacklogId -Backlog $backlog -Id ([string]$k.Id)
                    Write-CompanionLog ("request: id={0} re-request after done -> upgrade" -f $k.Id) 'OK'
                } elseif ($k.State -eq 'Pending' -and $k.ReRequested) {
                    $pq = [string]$k.PendingQid
                    if ([string]::IsNullOrWhiteSpace($pq) -or -not $qidIndex.ContainsKey($pq)) {
                        $requestSeq++
                        $k.State = 'Upgrade'
                        $k.PendingQid = ''
                        $k.Absent = 0
                        $k.RetryAt = [DateTime]::MinValue
                        $k.ReRequested = $false
                        $k.Seq = $requestSeq
                        Add-BacklogId -Backlog $backlog -Id ([string]$k.Id)
                        Write-CompanionLog ("request: id={0} re-request after pending copy vanished -> upgrade" -f $k.Id) 'OK'
                    } else {
                        $k.ReRequested = $false
                    }
                } elseif ($k.State -eq 'Playing' -or $k.State -eq 'New' -or $k.State -eq 'Upgrade') {
                    $k.ReRequested = $false
                }
            }
            Sort-BacklogBySeq -Backlog $backlog -Known $known

            # ---- NCM restart: only re-add pending d that are truly gone ---
            if ($ncmOk -and $ncmRestartPending) {
                $restartAge = [double]::MaxValue
                if ($lastNcmRestartAt -ne [DateTime]::MinValue) {
                    $restartAge = ((Get-Date) - $lastNcmRestartAt).TotalSeconds
                }
                $restartReady = ($restartAge -ge 8) -and (($ncmQueue.Count -gt 0) -or [string]::IsNullOrWhiteSpace($currentId) -or ($restartAge -ge 30))
                if (-not $restartReady) {
                    $restartBlocked = $true
                } else {
                    $missing = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($k in @($known.Values)) {
                        if (-not ($k.IsD -and $k.State -eq 'Pending')) { continue }
                        if ($currentId -and $k.Id -eq $currentId) {
                            $k.State = 'Playing'
                            continue
                        }
                        $pq = [string]$k.PendingQid
                        $pqIdx = -1
                        if (-not [string]::IsNullOrWhiteSpace($pq) -and $qidIndex.ContainsKey($pq)) {
                            $pqIdx = [int]$qidIndex[$pq]
                        }
                        if ($pqIdx -ge 0) {
                            if ($currentIndex -ge 0 -and $pqIdx -eq $currentIndex) {
                                $k.State = 'Playing'
                            } elseif ($currentIndex -ge 0 -and $pqIdx -lt $currentIndex) {
                                $k.State = 'Done'
                            }
                            continue
                        }
                        $indices = @()
                        if ($tidIndices.ContainsKey([string]$k.Id)) { $indices = @($tidIndices[[string]$k.Id]) }
                        if ($currentIndex -ge 0) {
                            $after = @($indices | Where-Object { $_ -gt $currentIndex })
                            if ($after.Count -gt 0) {
                                $newIdx = [int]$after[0]
                                $k.PendingQid = [string]$ncmQueue[$newIdx].qid
                                $k.Absent = 0
                                continue
                            }
                            $before = @($indices | Where-Object { $_ -lt $currentIndex })
                            if ($before.Count -gt 0) {
                                $k.State = 'Done'
                                continue
                            }
                        }
                        $missing.Add($k)
                    }

                    if ($missing.Count -gt 0) {
                        $ordered = @($missing | Sort-Object { [int]$_.Seq })
                        foreach ($k in $ordered) {
                            $k.State = 'Upgrade'
                            $k.PendingQid = ''
                            $k.Absent = 0
                            $k.RetryAt = [DateTime]::MinValue
                            $k.ReRequested = $false
                            Add-BacklogId -Backlog $backlog -Id ([string]$k.Id)
                            Write-CompanionLog ("NCM restart: re-adding missing pending d: id={0} name={1} seq={2}" -f $k.Id, $k.Name, $k.Seq) 'WARN'
                        }
                        Sort-BacklogBySeq -Backlog $backlog -Known $known
                    }
                    $ncmRestartHandled = $true
                    $ncmRestartPending = $false
                    Write-CompanionLog 'NCM restart reconciliation complete' 'OK'
                }
            }

            # ---- process at most one add/move per poll -----------------
            if ($ncmOk -and $sessionReady -and -not $restartBlocked) {
                $pendingQids = @(Get-PendingQidList -Known $known -Ncm $ncm)
                $processIndex = -1
                $now = Get-Date

                for ($i = 0; $i -lt $backlog.Count; $i++) {
                    $id = [string]$backlog[$i]
                    if (-not $known.ContainsKey($id)) {
                        $backlog.RemoveAt($i)
                        $i--
                        continue
                    }
                    $k = $known[$id]
                    if ($k.State -eq 'Done' -or $k.State -eq 'Legacy') {
                        $backlog.RemoveAt($i)
                        $i--
                        continue
                    }

                    if ($id -eq $currentId) {
                        if ($k.State -eq 'New' -or $k.State -eq 'Upgrade' -or $k.State -eq 'Pending') { $k.State = 'Playing' }
                        $k.Absent = 0
                        $k.ReRequested = $false
                        $backlog.RemoveAt($i)
                        $i--
                        Write-CompanionLog ("request: id={0} merge (currently playing)" -f $id) 'OK'
                        continue
                    }

                    if ($k.State -eq 'Pending') {
                        $pq = [string]$k.PendingQid
                        if (-not [string]::IsNullOrWhiteSpace($pq) -and $qidIndex.ContainsKey($pq)) {
                            $pqIdx = [int]$qidIndex[$pq]
                            if ($currentIndex -lt 0 -or $pqIdx -gt $currentIndex) {
                                $backlog.RemoveAt($i)
                                $i--
                                continue
                            }
                            if ($currentIndex -ge 0 -and $pqIdx -eq $currentIndex) {
                                $k.State = 'Playing'
                                $backlog.RemoveAt($i)
                                $i--
                                continue
                            }
                        }
                    }

                    if ($k.RetryAt -gt $now) { continue }
                    $processIndex = $i
                    break
                }

                if ($processIndex -ge 0) {
                    $id = [string]$backlog[$processIndex]
                    $k = $known[$id]
                    $occ = @()
                    if ($tidIndices.ContainsKey($id)) { $occ = @($tidIndices[$id]) }
                    $handled = $false
                    $currentIsSong = ($currentId -and $id -eq $currentId)

                    if ($currentIsSong) {
                        if ($k.State -eq 'New' -or $k.State -eq 'Upgrade' -or $k.State -eq 'Pending') { $k.State = 'Playing' }
                        $k.Absent = 0
                        $k.ReRequested = $false
                        $backlog.RemoveAt($processIndex)
                        Write-CompanionLog ("request: id={0} merge (currently playing)" -f $id) 'OK'
                        $handled = $true
                    }

                    if (-not $handled -and $occ.Count -gt 0) {
                        $move = Move-NcmQueueItem -SongId $id -Mode 'pending' -PendingQids $pendingQids
                        if ($move.Ok) {
                            $backlog.RemoveAt($processIndex)
                            $handled = $true
                            if ($move.MergedCurrent -or ($move.CurrentId -and $move.CurrentId -eq $id)) {
                                $k.State = 'Playing'
                                $k.Absent = 0
                                $k.ReRequested = $false
                                Write-CompanionLog ("request: id={0} merge (currently playing)" -f $id) 'OK'
                            } elseif ($move.CurrentIndex -ge 0 -and $move.Position -le $move.CurrentIndex) {
                                $k.State = 'Upgrade'
                                $k.PendingQid = ''
                                $k.RetryAt = (Get-Date).AddSeconds(5)
                                Add-BacklogId -Backlog $backlog -Id $id
                                Write-CompanionLog ("move did not land after current: id={0} pos={1} current={2}" -f $id, $move.Position, $move.CurrentIndex) 'ERROR'
                            } else {
                                $k.IsD = $true
                                $k.State = 'Pending'
                                $k.PendingQid = [string]$move.Qid
                                $k.Absent = 0
                                $k.RetryAt = [DateTime]::MinValue
                                $k.ReRequested = $false
                                Write-CompanionLog ("moved d: id={0} qid={1} from={2} anchor={3} pos={4} queue={5}" -f $id, $move.Qid, $move.From, $move.Anchor, $move.Position, $move.QueueLen) 'OK'
                            }
                        } elseif ($move.Error -eq 'not_in_queue') {
                            $occ = @()
                        } else {
                            $k.RetryAt = (Get-Date).AddSeconds(5)
                            Write-CompanionLog ("move failed: id={0} error={1}" -f $id, $move.Error) 'WARN'
                            $handled = $true
                        }
                    }

                    if (-not $handled -and $occ.Count -eq 0) {
                        $anchor = Get-PendingAnchor -Queue $ncmQueue -Known $known -CurrentIndex $currentIndex
                        $add = Add-NcmSong -SongId $id -Source 'queue' -Offset $anchor -Mode 'pending' -PendingQids $pendingQids
                        if ($add.Ok) {
                            if ($add.MergedCurrent -or $add.Started -or ($add.Current -and [string]$add.Current.id -eq $id)) {
                                $k.State = 'Playing'
                                $k.Absent = 0
                                $k.ReRequested = $false
                                $backlog.RemoveAt($processIndex)
                                Write-CompanionLog ("request: id={0} started playing after add" -f $id) 'OK'
                            } elseif ($add.Existed -and -not $add.Added) {
                                # Another request/queue copy appeared between the
                                # check and the insert. Move that copy instead of
                                # leaving a duplicate or a misordered item.
                                $move = Move-NcmQueueItem -SongId $id -Mode 'pending' -PendingQids $pendingQids
                                if ($move.Ok -and ($move.MergedCurrent -or ($move.CurrentId -and $move.CurrentId -eq $id))) {
                                    $k.State = 'Playing'
                                    $k.Absent = 0
                                    $k.ReRequested = $false
                                    $backlog.RemoveAt($processIndex)
                                    Write-CompanionLog ("request: id={0} merge (currently playing)" -f $id) 'OK'
                                } elseif ($move.Ok -and -not ($move.CurrentIndex -ge 0 -and $move.Position -le $move.CurrentIndex)) {
                                    $k.State = 'Pending'
                                    $k.PendingQid = [string]$move.Qid
                                    $k.Absent = 0
                                    $k.RetryAt = [DateTime]::MinValue
                                    $k.ReRequested = $false
                                    $backlog.RemoveAt($processIndex)
                                    Write-CompanionLog ("moved d: id={0} qid={1} from={2} anchor={3} pos={4} queue={5}" -f $id, $move.Qid, $move.From, $move.Anchor, $move.Position, $move.QueueLen) 'OK'
                                } else {
                                    $k.State = 'Upgrade'
                                    $k.PendingQid = ''
                                    $k.RetryAt = (Get-Date).AddSeconds(5)
                                    Write-CompanionLog ("existing copy move failed: id={0} error={1}" -f $id, $move.Error) 'WARN'
                                }
                            } else {
                                if ($add.CurrentIndex -ge 0 -and $add.Position -le $add.CurrentIndex) {
                                    $k.State = 'Upgrade'
                                    $k.PendingQid = ''
                                    $k.RetryAt = (Get-Date).AddSeconds(2)
                                    Add-BacklogId -Backlog $backlog -Id $id
                                    Write-CompanionLog ("add landed before current: id={0} pos={1} current={2}" -f $id, $add.Position, $add.CurrentIndex) 'ERROR'
                                } else {
                                    $k.IsD = $true
                                    $k.State = 'Pending'
                                    $k.PendingQid = [string]$add.Qid
                                    $k.Absent = 0
                                    $k.RetryAt = [DateTime]::MinValue
                                    $k.ReRequested = $false
                                    $backlog.RemoveAt($processIndex)
                                    Write-CompanionLog ("queued d: id={0} anchor={1} pos={2} qid={3} queue={4}" -f $id, $add.Anchor, $add.Position, $add.Qid, $add.QueueLen) 'OK'
                                }
                            }
                        } else {
                            $k.RetryAt = (Get-Date).AddSeconds(10)
                            Write-CompanionLog ("queue add failed: id={0} error={1}" -f $id, $add.Error) 'WARN'
                        }
                    }
                }
            }

            # ---- overlay state -----------------------------------------
            $state = New-OverlayState -Ncm $ncm -NcmOk $ncmOk -BotData $botData -Known $known -CurrentId $currentId -Alert $alert -BotAutoPlay $botAutoPlay
            Write-OverlayState -State $state

        } catch {
            Write-CompanionLog ('loop error: ' + $_.Exception.Message) 'ERROR'
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
} finally {
    if ($haveMutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    try { $mutex.Dispose() } catch { }
}
