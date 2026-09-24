import QtQuick
import Quickshell
import Quickshell.Io
import "PlexApi.js" as PlexApi

// Ampbar service: owns the Plex session, the play queue, and the headless mpv
// process that actually makes sound. The bar widget is a pure view over this.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  // The shell hands third-party plugins a manifest without its source
  // directory, so the helpers are located relative to this file instead.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string authScript: pluginDir ? pluginDir + "/bin/plexamp-auth" : ""
  readonly property string waveScript: pluginDir ? pluginDir + "/bin/plexamp-waveform" : ""
  readonly property string engineScript: pluginDir ? pluginDir + "/bin/plexamp-engine" : ""
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/omarchy/plexamp"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy/plexamp"
  // Omarchy supplies a per-user runtime directory. Avoid /tmp: an IPC socket
  // there would be globally predictable and weaker than the 0700 runtime dir.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string socketPath: runtimeDir ? runtimeDir + "/omarchy-ampbar.sock" : ""

  // ---------------------------------------------------------------- session

  // "unknown" until auth.json is read, then one of:
  // "logged-out" | "linking" | "ready" | "error"
  property string authState: "unknown"
  property string authError: ""
  property string pinCode: ""
  property string pinUrl: ""

  property string serverName: ""
  property string serverUri: ""
  property string serverToken: ""
  property string machineIdentifier: ""
  property string clientId: ""

  readonly property bool ready: authState === "ready" && serverUri !== "" && serverToken !== ""

  // ---------------------------------------------------------------- playback

  property var queue: []
  property int queueIndex: -1
  readonly property var currentTrack: (queueIndex >= 0 && queueIndex < queue.length) ? queue[queueIndex] : null
  readonly property bool hasTrack: currentTrack !== null
  // Radio needs either an artist to seed from or a station to fall back on;
  // without one the button has nothing to do and says so by dimming.
  readonly property bool canStartRadio: ready
    && ((currentTrack !== null && currentTrack.artistKey !== "") || stations.length > 0)

  // "" for a plain list, "radio" for a server-side station that keeps
  // generating tracks as we approach the end of what we already hold.
  property string queueSource: ""
  property string queueTitle: ""
  property int playQueueId: 0

  property bool isPlaying: false
  // True only after mpv confirms it has media loaded. This prevents a saved
  // queue from making Play unpause an otherwise idle mpv after a cold start.
  property bool engineHasFile: false
  property real position: 0
  property real duration: 0
  property int volume: 70
  property bool muted: false
  property string playbackError: ""

  // Loudness envelope for the current track, drawn as the seek bar.
  property var waveform: []
  property string waveformKey: ""

  // Plex's four-corner album palette, which colours the whole panel.
  property var tint: null
  property var _tintCache: ({})
  property string _tintAlbumKey: ""

  readonly property real progress: duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0
  readonly property bool canNext: queueIndex >= 0 && queueIndex < queue.length - 1
  readonly property bool canPrevious: queueIndex > 0

  // Everything the queue still has to play, in order. The Next up tab and the
  // mini viewer's up-next strip both read this.
  readonly property var upNext: {
    var out = []
    for (var i = queueIndex + 1; i < queue.length; i++) out.push(queue[i])
    return out
  }

  // ---------------------------------------------------------------- library

  property bool loading: false
  property string statusMessage: ""

  // A server can host several music libraries; we remember which one the user
  // last used and default to the biggest one rather than whichever came first.
  property var musicSections: []
  property string musicSectionKey: ""
  readonly property string musicSectionTitle: {
    for (var i = 0; i < musicSections.length; i++)
      if (musicSections[i].key === musicSectionKey) return musicSections[i].title
    return ""
  }

  // The first two Home sections deliberately stay compact. History has its
  // own configurable depth below them.
  property int homeLimit: 5
  property int historyLimit: 40

  property var homePlayed: []      // most-played albums (or radio fallbacks) this month
  property var homeAdded: []       // recently added albums
  property var history: []         // recently played tracks, newest first
  property var stations: []        // server-generated radio stations

  // One level of drill-down: album or artist contents, over any tab.
  property string browseMode: ""   // "" | "album" | "artist"
  property string browseTitle: ""
  property var browseTracks: []
  property var browseAlbums: []
  // Artist view, split into albums / singles & EPs / everything else:
  // [{ title, items }] for albums / singles & EPs / everything else.
  property var browseGroups: []

  // ----------------------------------------------------------------- search

  property string searchQuery: ""
  property bool searching: false
  property var searchTracks: []
  property var searchAlbums: []
  property var searchArtists: []
  readonly property bool searchEmpty: searchTracks.length === 0
    && searchAlbums.length === 0 && searchArtists.length === 0

  // ------------------------------------------------------------ preferences

  // Options the settings window can change. They live in the plugin's own
  // state file rather than shell.json, because a plugin cannot safely rewrite
  // the shell config from underneath the shell.
  property var prefs: ({})

  function pref(name, fallback) {
    var value = prefs ? prefs[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function setPref(name, value) {
    var next = {}
    for (var k in prefs) next[k] = prefs[k]
    next[name] = value
    prefs = next
    persistState()
  }

  signal browseLoaded()
  signal searchLoaded()

  // ============================================================ credentials

  // Bumped whenever the session changes so replies from the old one are
  // dropped instead of repopulating the panel after a sign-out.
  property int _sessionGeneration: 0

  FileView {
    id: authFile
    path: root.configDir + "/auth.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyAuth(text())
    onLoadFailed: root.applyAuth("")
    onFileChanged: reload()
  }

  function applyAuth(raw) {
    var text = String(raw || "").trim()
    var data = null
    try {
      data = text ? JSON.parse(text) : null
    } catch (e) {
      data = null
    }
    var valid = !!(data && data.serverUri && (data.serverToken || data.accountToken))
    var uri = valid ? String(data.serverUri) : ""
    var token = valid ? String(data.serverToken || data.accountToken) : ""
    // Anything already loaded belongs to the old credentials.
    if (serverUri && (uri !== serverUri || token !== serverToken)) clearSession()
    if (!valid) {
      if (text && !data) {
        authState = "error"
        authError = "credentials file is not valid JSON"
      } else if (authState !== "linking") {
        authState = "logged-out"
      }
      return
    }
    serverUri = uri
    serverToken = token
    serverName = String(data.serverName || "Plex")
    machineIdentifier = String(data.machineIdentifier || "")
    clientId = String(data.clientIdentifier || "")
    authError = ""
    pinCode = ""
    pinUrl = ""
    authState = "ready"
    refreshLibrary()
    tryRestorePlayback()
  }

  function login() {
    if (!authScript) {
      authState = "error"
      authError = "plugin directory unknown; cannot start sign-in"
      return
    }
    if (authProcess.running) return
    authError = ""
    pinCode = ""
    pinUrl = ""
    authState = "linking"
    authProcess.command = [authScript, "login"]
    authProcess.running = true
  }

  function clearSession() {
    _sessionGeneration++
    cancelRequests()
    clearArtwork()
    _tintCache = ({})
    _tintAlbumKey = ""
    stop()
    shutdownEngine()
    waveQueue = []
    if (waveProcess.running) waveProcess.signal(15)
    waveProcess.streamUrl = ""
    waveform = []
    waveCache = ({})
    restoreRetry.stop()
    _playbackRestoring = false
    loading = false
    searching = false
    queue = []
    queueIndex = -1
    queueSource = ""
    queueTitle = ""
    playQueueId = 0
    persistPlayback()
    homePlayed = []
    homeAdded = []
    history = []
    stations = []
    musicSections = []
    musicSectionKey = ""
    clearSearch()
    clearBrowse()
    _savedPlayback = null
    serverUri = ""
    serverToken = ""
    serverName = ""
    machineIdentifier = ""
    clientId = ""
  }

  function logout() {
    clearSession()
    authState = "logged-out"
    if (authProcess.running) authProcess.signal(15)
    if (serverProcess.running) serverProcess.signal(15)
    serverBusy = false
    if (!authScript) return
    logoutProcess.command = [authScript, "logout"]
    logoutProcess.running = true
  }

  // True while plexamp-auth is re-pointing us at a server. The settings window
  // shows it so the user knows the address is being probed, not ignored.
  property bool serverBusy: false

  // Point the plugin at a specific address. Discovery normally picks one, but
  // it favours the connection plex.tv advertises, which is not always the one
  // that works from this machine.
  function setServer(uri) {
    var target = String(uri || "").trim()
    if (!authScript || serverProcess.running || !target) return
    serverBusy = true
    authError = ""
    serverProcess.command = [authScript, "server", target]
    serverProcess.running = true
  }

  function rediscoverServer() {
    if (!authScript || serverProcess.running) return
    serverBusy = true
    authError = ""
    serverProcess.command = [authScript, "rediscover"]
    serverProcess.running = true
  }

  Process {
    id: serverProcess
    running: false
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        var trimmed = String(line || "").trim()
        if (!trimmed) return
        var msg = null
        try {
          msg = JSON.parse(trimmed)
        } catch (e) {
          return
        }
        if (!msg) return
        if (String(msg.stage || "") === "error")
          root.authError = String(msg.message || "could not reach that server")
      }
    }
    onExited: {
      root.serverBusy = false
      // write_auth swaps the file in by rename, which the watcher can miss.
      authFile.reload()
      if (root.ready) root.refreshLibrary()
    }
  }

  function cancelLogin() {
    if (authProcess.running) authProcess.signal(15)
    pinCode = ""
    pinUrl = ""
    authState = serverUri ? "ready" : "logged-out"
  }

  Process {
    id: authProcess
    running: false
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        var trimmed = String(line || "").trim()
        if (!trimmed) return
        var msg = null
        try {
          msg = JSON.parse(trimmed)
        } catch (e) {
          return
        }
        root.handleAuthMessage(msg)
      }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (String(line || "").trim() !== "") console.warn("plexamp/auth:", line)
      }
    }
    onExited: function (code) {
      if (code !== 0 && root.authState === "linking") {
        root.authState = "error"
        if (!root.authError) root.authError = "sign-in failed"
      }
    }
  }

  Process {
    id: logoutProcess
    running: false
  }

  function handleAuthMessage(msg) {
    switch (String(msg.stage || "")) {
    case "pin":
      pinCode = String(msg.code || "")
      pinUrl = String(msg.url || "")
      authState = "linking"
      break
    case "waiting":
      authState = "linking"
      break
    case "token":
      statusMessage = "Signed in — finding your server…"
      break
    case "server":
      statusMessage = "Connected to " + String(msg.name || "Plex")
      break
    case "done":
      pinCode = ""
      pinUrl = ""
      authFile.reload()
      break
    case "logged-out":
      authState = "logged-out"
      break
    case "error":
      authState = "error"
      authError = String(msg.message || "sign-in failed")
      break
    }
  }

  // =============================================================== Plex HTTP

  // Plex replies are buffered and parsed inside the shell process, so each
  // request is bounded in time and size. A server that stalls, trickles, or
  // streams without end is cut off instead of holding a socket open or
  // growing the shell's memory. Plex spends about 1.4 KB per track, so the
  // cap still fits an artist's /allLeaves of some 12,000 tracks. Opening the
  // panel sends several requests at once, so everything in flight also shares
  // one budget: many replies each just under the cap cannot add up either.
  readonly property int apiTimeoutMs: 30000
  readonly property int apiMaxResponseBytes: 16 * 1024 * 1024
  readonly property int apiMaxInFlightBytes: 32 * 1024 * 1024
  property var _pendingRequests: []

  function apiRequest(method, path, params, onSuccess, onFailure) {
    if (!serverUri || !serverToken) {
      if (onFailure) onFailure("not connected")
      return
    }
    var query = params || {}
    query["X-Plex-Token"] = serverToken
    var target = PlexApi.url(serverUri, path, query)
    fetchBounded(method, target, "application/json", apiMaxResponseBytes, function (xhr) {
      var parsed = null
      try {
        parsed = JSON.parse(xhr.responseText)
      } catch (e) {
        if (onFailure) onFailure("unreadable response from Plex")
        return
      }
      if (onSuccess) onSuccess(parsed)
    }, onFailure)
  }

  // Every request to the server goes through here: JSON and cover art alike.
  // onSuccess receives the finished XMLHttpRequest for a 2xx reply.
  function fetchBounded(method, target, accept, maxBytes, onSuccess, onFailure) {
    var xhr = new XMLHttpRequest()
    var generation = _sessionGeneration
    var pending = { xhr: xhr, deadline: Date.now() + apiTimeoutMs, bytes: 0, error: "" }
    // Qt keeps using the network reply after a readystatechange handler
    // returns, so aborting from inside one crashes the shell. From a handler
    // the abort waits for it to unwind; the timer, sign-out, and teardown
    // abort at once. The reason is recorded first, and DONE (from abort() or
    // a reply that finishes first) reports it.
    function cancel(error, immediately) {
      if (pending.error) return
      pending.error = error
      if (immediately) xhr.abort()
      else Qt.callLater(function () { xhr.abort() })
    }
    pending.cancel = cancel
    function tooLarge() {
      // An arraybuffer response exposes the bytes received so far without
      // copying or decoding them, which makes this check cheap per chunk.
      var body = xhr.response
      pending.bytes = body ? body.byteLength : 0
      if (pending.bytes > maxBytes) return true
      var total = 0
      for (var i = 0; i < root._pendingRequests.length; i++)
        total += root._pendingRequests[i].bytes
      return total > root.apiMaxInFlightBytes
    }
    xhr.onreadystatechange = function () {
      if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED) {
        var declared = Number(xhr.getResponseHeader("Content-Length"))
        if (declared > maxBytes) cancel("response from Plex was too large")
        return
      }
      if (xhr.readyState === XMLHttpRequest.LOADING) {
        if (tooLarge()) cancel("response from Plex was too large")
        return
      }
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var at = root._pendingRequests.indexOf(pending)
      if (at >= 0) root._pendingRequests.splice(at, 1)
      if (!root._pendingRequests.length) requestDeadline.stop()
      if (generation !== root._sessionGeneration) return
      if (pending.error) {
        if (onFailure) onFailure(pending.error)
        return
      }
      // The final chunk can arrive together with DONE. This reply has left
      // the shared budget, so only its own cap applies now.
      if (xhr.response && xhr.response.byteLength > maxBytes) {
        if (onFailure) onFailure("response from Plex was too large")
        return
      }
      if (xhr.status >= 200 && xhr.status < 300) {
        if (onSuccess) onSuccess(xhr)
      } else if (onFailure) {
        onFailure(xhr.status === 0 ? "could not reach " + root.serverName
                                   : "Plex returned HTTP " + xhr.status)
      }
    }
    xhr.responseType = "arraybuffer"
    xhr.open(method, target)
    xhr.setRequestHeader("Accept", accept)
    if (clientId) xhr.setRequestHeader("X-Plex-Client-Identifier", clientId)
    _pendingRequests.push(pending)
    requestDeadline.running = true
    xhr.send()
  }

  // One shared clock enforces the total deadline, however slowly the bytes
  // arrive; per-chunk activity never extends it.
  function expireRequests(now) {
    var expired = _pendingRequests.filter(function (p) { return now >= p.deadline })
    for (var i = 0; i < expired.length; i++)
      expired[i].cancel("Plex took too long to respond", true)
    if (!_pendingRequests.length) requestDeadline.stop()
  }

  // Never called from inside a request's own handler, so it aborts at once.
  function cancelRequests() {
    var all = _pendingRequests.slice()
    for (var i = 0; i < all.length; i++) all[i].cancel("cancelled", true)
  }

  Timer {
    id: requestDeadline
    interval: 1000
    repeat: true
    running: false
    onTriggered: root.expireRequests(Date.now())
  }

  function request(path, params, onSuccess, onFailure) {
    apiRequest("GET", path, params, onSuccess, onFailure)
  }

  // ================================================================ artwork

  // Qt's image loader would buffer a reply of any size with no deadline, so
  // cover art is fetched through fetchBounded as well and reaches Image as a
  // data: URL. Plex's 600px transcodes stay under 600 KB (10-70 KB typical).
  readonly property int artMaxBytes: 2 * 1024 * 1024
  // Base64 characters kept across all cached covers; far more than a panel
  // full of covers needs, but a server serving oversized ones still can't
  // grow it.
  readonly property int artCacheChars: 32 * 1024 * 1024
  // A cover that failed or was evicted is not asked for again sooner, so an
  // oversized cover can't be fetched in a loop.
  readonly property int artRetryMs: 5 * 60 * 1000
  // Bumped as covers arrive, so bindings that called artwork() look again.
  property int artRevision: 0
  property var _art: ({})     // url -> { data: data: URL or "", at: last fetch }
  property var _artOrder: []  // cached urls, oldest first
  property int _artChars: 0

  // For Image.source bindings: the cover as a data: URL once it has arrived,
  // "" until then or if it can't be had.
  function artwork(url) {
    var revision = artRevision
    if (!url) return ""
    var entry = _art[url]
    if (entry && (entry.data || Date.now() - entry.at < artRetryMs)) return entry.data
    loadArtwork(url)
    return ""
  }

  function loadArtwork(url) {
    var entry = { data: "", at: Date.now() }
    _art[url] = entry
    // Covers only ever come from the signed-in server.
    if (!serverUri || String(url).indexOf(serverUri + "/") !== 0) return
    fetchBounded("GET", url, "image/*", artMaxBytes, function (xhr) {
      var type = String(xhr.getResponseHeader("Content-Type") || "").split(";")[0].trim().toLowerCase()
      if (!/^image\/(jpeg|png|webp|gif)$/.test(type) || root._art[url] !== entry) return
      entry.data = "data:" + type + ";base64," + root.base64(new Uint8Array(xhr.response))
      root._artOrder.push(url)
      root._artChars += entry.data.length
      while (root._artChars > root.artCacheChars && root._artOrder.length > 1) {
        var old = root._art[root._artOrder.shift()]
        root._artChars -= old.data.length
        old.data = ""
        old.at = Date.now()
      }
      root.artRevision++
    }, function () {})
  }

  function clearArtwork() {
    _art = ({})
    _artOrder = []
    _artChars = 0
    artRevision++
  }

  function base64(bytes) {
    var table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    var out = []
    var i = 0
    for (; i + 2 < bytes.length; i += 3) {
      var v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]
      out.push(table[v >> 18] + table[(v >> 12) & 63] + table[(v >> 6) & 63] + table[v & 63])
    }
    if (i < bytes.length) {
      var two = i + 1 < bytes.length
      var r = (bytes[i] << 16) | ((two ? bytes[i + 1] : 0) << 8)
      out.push(table[r >> 18] + table[(r >> 12) & 63] + (two ? table[(r >> 6) & 63] : "=") + "=")
    }
    return out.join("")
  }

  // ============================================================== libraries

  function refreshLibrary() {
    if (!ready) return
    loading = true
    statusMessage = ""
    request("/library/sections", {}, function (response) {
      var sections = PlexApi.musicSections(response)
      if (!sections.length) {
        root.loading = false
        root.statusMessage = "No music library found on " + root.serverName
        return
      }
      root.musicSections = sections
      // A remembered choice wins; otherwise measure and take the biggest.
      var wanted = root.musicSectionKey || root._savedSectionKey
      for (var i = 0; i < sections.length; i++) {
        if (sections[i].key === wanted) {
          root.musicSectionKey = wanted
          root.loadSection()
          return
        }
      }
      root.measureSections(sections, 0)
    }, function (error) {
      root.loading = false
      root.statusMessage = error
    })
  }

  // Track counts aren't in /library/sections, so ask each library for a
  // zero-length page and read totalSize off the container.
  function measureSections(sections, index) {
    if (index >= sections.length) {
      var best = sections[0]
      for (var i = 1; i < sections.length; i++)
        if (sections[i].size > best.size) best = sections[i]
      musicSectionKey = best.key
      persistState()
      loadSection()
      return
    }
    request("/library/sections/" + sections[index].key + "/all", {
      "type": 10,
      "X-Plex-Container-Start": 0,
      "X-Plex-Container-Size": 0
    }, function (response) {
      var copy = sections.slice()
      copy[index] = {
        key: sections[index].key,
        title: sections[index].title,
        size: Number(PlexApi.container(response).totalSize || 0)
      }
      root.musicSections = copy
      root.measureSections(copy, index + 1)
    }, function () {
      root.measureSections(sections, index + 1)
    })
  }

  function selectSection(key) {
    if (!key || key === musicSectionKey) return
    musicSectionKey = key
    persistState()
    loadSection()
  }

  // Step through the server's music libraries when it has more than one.
  function cycleSection(direction) {
    if (musicSections.length < 2) return
    var at = 0
    for (var i = 0; i < musicSections.length; i++)
      if (musicSections[i].key === musicSectionKey) at = i
    var next = (at + (direction || 1) + musicSections.length) % musicSections.length
    selectSection(musicSections[next].key)
  }

  function loadSection() {
    if (!ready || !musicSectionKey) return
    clearBrowse()
    clearSearch()
    homePlayed = []
    homeAdded = []
    history = []
    stations = []
    loadHome()
    loadStations()
  }

  function loadHome() {
    loadMostPlayedThisMonth()
    loadRecentlyAdded()
    loadHistory()
  }

  function loadMostPlayedThisMonth() {
    if (!ready || !musicSectionKey) return
    loading = true
    var today = new Date()
    // Plex timestamps are Unix seconds. Asking the server for the month keeps
    // a long listening history from dominating the result; the parser applies
    // the same boundary as a guard for older servers that ignore this filter.
    var monthStart = Math.floor(new Date(today.getFullYear(), today.getMonth(), 1).getTime() / 1000)
    request("/status/sessions/history/all", {
      "sort": "viewedAt:desc",
      "librarySectionID": musicSectionKey,
      "viewedAt>>": monthStart,
      "X-Plex-Container-Start": 0,
      "X-Plex-Container-Size": 500
    }, function (response) {
      var entries = PlexApi.historyEntries(response)
      root.homePlayed = PlexApi.mostPlayedThisMonth(root.serverUri, root.serverToken,
                                                     entries, monthStart, root.homeLimit)
      root.loading = false
    }, function (error) {
      root.loading = false
      root.statusMessage = error
    })
  }

  function loadRecentlyAdded() {
    if (!ready || !musicSectionKey) return
    request("/library/sections/" + musicSectionKey + "/all", {
      "type": 9,
      "sort": "addedAt:desc",
      "X-Plex-Container-Start": 0,
      "X-Plex-Container-Size": homeLimit
    }, function (response) {
      root.homeAdded = PlexApi.albums(root.serverUri, root.serverToken, response)
    }, function (error) {
      root.statusMessage = error
    })
  }

  // History rows arrive without a Media section, so resolve the ratingKeys in
  // one batched metadata call to get streamable URLs.
  function loadHistory() {
    if (!ready || !musicSectionKey) return
    request("/status/sessions/history/all", {
      "sort": "viewedAt:desc",
      "librarySectionID": musicSectionKey,
      "X-Plex-Container-Start": 0,
      "X-Plex-Container-Size": historyLimit
    }, function (response) {
      var entries = PlexApi.historyEntries(response)
      var keys = PlexApi.uniqueKeys(entries)
      if (!keys.length) {
        root.history = []
        return
      }
      root.request("/library/metadata/" + keys.join(","), {}, function (detail) {
        var map = PlexApi.trackMap(root.serverUri, root.serverToken, detail)
        root.history = PlexApi.resolveHistory(root.serverUri, root.serverToken, entries, map)
      }, function (error) {
        root.statusMessage = error
      })
    }, function (error) {
      root.statusMessage = error
    })
  }

  function loadStations() {
    if (!ready || !musicSectionKey) return
    request("/hubs/sections/" + musicSectionKey, {
      "count": 1,
      "includeStations": 1
    }, function (response) {
      root.stations = PlexApi.stations(response)
    }, function (error) {
      root.statusMessage = error
    })
  }

  function openAlbum(ratingKey, title) {
    if (!ready || !ratingKey) return
    loading = true
    browseMode = "album"
    browseTitle = title || "Album"
    browseAlbums = []
    request("/library/metadata/" + ratingKey + "/children", {}, function (response) {
      root.browseTracks = PlexApi.tracks(root.serverUri, root.serverToken, response)
      root.loading = false
      root.browseLoaded()
    }, function (error) {
      root.loading = false
      root.browseTracks = []
      root.statusMessage = error
    })
  }

  function openArtist(ratingKey, title) {
    if (!ready || !ratingKey) return
    loading = true
    browseMode = "artist"
    browseTitle = title || "Artist"
    browseTracks = []
    browseGroups = []
    request("/library/metadata/" + ratingKey + "/children", {}, function (response) {
      var releases = PlexApi.albums(root.serverUri, root.serverToken, response)
      root.browseAlbums = releases
      // One extra call gets every track this artist has, which is the only
      // cheap way to learn how many tracks each release holds.
      root.request("/library/metadata/" + ratingKey + "/allLeaves", {}, function (leaves) {
        root.applyArtistGroups(releases, leaves)
      }, function () {
        root.applyArtistGroups(releases, null)
      })
    }, function (error) {
      root.loading = false
      root.browseAlbums = []
      root.browseGroups = []
      root.statusMessage = error
    })
  }

  function applyArtistGroups(releases, leaves) {
    var counts = leaves ? PlexApi.trackCountsByAlbum(leaves) : {}

    // /children only lists releases the artist is the *album* artist of; the
    // rest (loose singles, features, compilations) only turn up in /allLeaves.
    var known = {}
    for (var i = 0; i < releases.length; i++) known[String(releases[i].ratingKey)] = true
    var extras = leaves
      ? PlexApi.albumsFromLeaves(serverUri, serverToken, leaves, known)
      : []

    var grouped = PlexApi.groupArtistAlbums(releases.concat(extras), counts)
    var groups = []
    if (grouped.main.length) groups.push({ title: "Albums", items: grouped.main })
    if (grouped.singles.length) groups.push({ title: "Singles & EPs", items: grouped.singles })
    if (grouped.other.length) groups.push({ title: "Other releases", items: grouped.other })
    browseGroups = groups
    browseAlbums = grouped.main.concat(grouped.singles, grouped.other)
    loading = false
    browseLoaded()
  }

  function browseCurrentArtist() {
    if (currentTrack && currentTrack.artistKey)
      openArtist(currentTrack.artistKey, currentTrack.artist)
  }

  function browseCurrentAlbum() {
    if (currentTrack && currentTrack.albumKey)
      openAlbum(currentTrack.albumKey, currentTrack.album)
  }

  function clearBrowse() {
    browseMode = ""
    browseTitle = ""
    browseTracks = []
    browseAlbums = []
    browseGroups = []
  }

  // Play everything under an album without leaving the current view.
  function playAlbum(ratingKey, title) {
    if (!ready || !ratingKey) return
    request("/library/metadata/" + ratingKey + "/children", {}, function (response) {
      var items = PlexApi.tracks(root.serverUri, root.serverToken, response)
      if (items.length) root.playQueue(items, 0, "", title || "")
    }, function (error) {
      root.statusMessage = error
    })
  }

  // ================================================================= search

  function search(query) {
    var q = String(query || "").trim()
    searchQuery = q
    if (!ready || q.length < 2) {
      clearSearchResults()
      searching = false
      return
    }
    searching = true
    request("/hubs/search", {
      "query": q,
      "limit": 12,
      "sectionId": musicSectionKey
    }, function (response) {
      // A stale reply from a query the user has already typed past.
      if (root.searchQuery !== q) return
      var results = PlexApi.searchResults(root.serverUri, root.serverToken, response)
      root.searchTracks = results.tracks
      root.searchAlbums = results.albums
      root.searchArtists = results.artists
      root.searching = false
      root.searchLoaded()
    }, function (error) {
      if (root.searchQuery !== q) return
      root.searching = false
      root.statusMessage = error
    })
  }

  function clearSearchResults() {
    searchTracks = []
    searchAlbums = []
    searchArtists = []
  }

  function clearSearch() {
    searchQuery = ""
    searching = false
    clearSearchResults()
  }

  // ================================================================== radio

  function playStation(key, title) {
    if (!ready || !key) return
    var uri = PlexApi.stationUri(machineIdentifier, key)
    if (!uri) {
      statusMessage = "This server did not report an identifier for radio"
      return
    }
    loading = true
    apiRequest("POST", "/playQueues", {
      "type": "audio",
      "repeat": 0,
      "own": 1,
      "uri": uri
    }, function (response) {
      var items = PlexApi.tracks(root.serverUri, root.serverToken, response)
      root.loading = false
      if (!items.length) {
        root.statusMessage = "Plex returned an empty station"
        return
      }
      root.playQueueId = Number(PlexApi.container(response).playQueueID || 0)
      root.playQueue(items, 0, "radio", title || "Radio")
    }, function (error) {
      root.loading = false
      root.statusMessage = error
    })
  }

  // Plex builds artist radio from a seed track/artist rather than a station id.
  function playArtistRadio(artistKey, title) {
    if (!artistKey) return
    playStation("/library/metadata/" + artistKey + "/station/1",
                title ? title + " radio" : "Artist radio")
  }

  function radioForCurrentArtist() {
    if (currentTrack && currentTrack.artistKey) {
      playArtistRadio(currentTrack.artistKey, currentTrack.artist)
      return
    }
    // Nothing loaded, so there is no artist to seed from: fall back to the
    // library's own station, which makes the radio keybind a "just play
    // something" button when the player is idle.
    if (stations.length) playStation(stations[0].key, stations[0].title)
    else statusMessage = "No radio available for this track"
  }

  // A station keeps generating tracks; pull the newly added tail before we
  // run off the end of what we already hold.
  function extendRadio() {
    if (queueSource !== "radio" || !playQueueId) return
    request("/playQueues/" + playQueueId, {
      "own": 1,
      "window": 200
    }, function (response) {
      var items = PlexApi.tracks(root.serverUri, root.serverToken, response)
      if (items.length <= root.queue.length) return
      var anchor = root.currentTrack ? String(root.currentTrack.ratingKey) : ""
      var at = root.queueIndex
      for (var i = 0; i < items.length; i++) {
        if (anchor && String(items[i].ratingKey) === anchor) {
          at = i
          break
        }
      }
      root.queue = items
      root.queueIndex = Math.max(0, Math.min(at, items.length - 1))
      root.persistPlayback()
      // The tail we just pulled in is what mpv should be prefetching.
      root.queueNext()
    }, function () {
      // Station exhausted or the queue expired; playback just ends normally.
    })
  }

  // ================================================= waveform + album tint

  // The analyser caches per ratingKey on disk, so a track it has already seen
  // comes back in milliseconds and never touches the network. This second,
  // in-memory cache exists so the track *after* the one playing can be analysed
  // in advance and drawn the instant it starts.
  property var waveCache: ({})     // ratingKey -> peaks
  property var waveQueue: []       // jobs waiting for the analyser
  property var waveJob: null       // the job the analyser is chewing on

  Process {
    id: waveProcess
    running: false
    stdinEnabled: true
    property string streamUrl: ""
    property int sessionGeneration: 0
    onStarted: {
      write(streamUrl + "\n")
      streamUrl = ""
    }
    onExited: {
      root.waveJob = null
      root.startWaveJob()
    }
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (waveProcess.sessionGeneration !== root._sessionGeneration) return
        var trimmed = String(line || "").trim()
        if (!trimmed) return
        var msg = null
        try {
          msg = JSON.parse(trimmed)
        } catch (e) {
          return
        }
        if (msg.stage !== "waveform" || !Array.isArray(msg.peaks)) return
        root.rememberWaveform(String(msg.ratingKey), msg.peaks)
      }
    }
  }

  function rememberWaveform(key, peaks) {
    var next = {}
    var keys = Object.keys(waveCache)
    // Keep the map from growing without bound across a long radio session.
    var from = Math.max(0, keys.length - 60)
    for (var i = from; i < keys.length; i++) next[keys[i]] = waveCache[keys[i]]
    next[key] = peaks
    waveCache = next
    if (currentTrack && String(currentTrack.ratingKey) === key) {
      waveform = peaks
      waveformKey = key
    }
  }

  function requestWaveform() {
    var track = currentTrack
    if (!track || !track.ratingKey) {
      waveform = []
      waveformKey = ""
      return
    }
    var key = String(track.ratingKey)
    var cached = waveCache[key]
    if (cached) {
      waveform = cached
      waveformKey = key
      return
    }
    waveform = []
    waveformKey = ""
    enqueueWaveform(track, true)
  }

  // Analysed while the current track is still playing, so the timeline is
  // already drawn when the next one takes over.
  function prefetchWaveform(track) {
    if (!track || !track.ratingKey) return
    if (waveCache[String(track.ratingKey)]) return
    enqueueWaveform(track, false)
  }

  function enqueueWaveform(track, urgent) {
    if (!waveScript || !track.stream || !track.ratingKey) return
    var key = String(track.ratingKey)
    if (waveJob && waveJob.key === key) return
    var jobs = waveQueue.slice()
    for (var i = 0; i < jobs.length; i++) if (jobs[i].key === key) return
    var job = { "key": key, "stream": track.stream }
    if (urgent) jobs.unshift(job)
    else jobs.push(job)
    waveQueue = jobs.slice(0, 4)
    startWaveJob()
  }

  function startWaveJob() {
    if (waveJob || !waveQueue.length || waveProcess.running) return
    var jobs = waveQueue.slice()
    var job = jobs.shift()
    waveQueue = jobs
    waveJob = job
    waveProcess.streamUrl = job.stream
    waveProcess.sessionGeneration = _sessionGeneration
    waveProcess.command = [waveScript, job.key]
    waveProcess.running = true
  }

  function requestTint() {
    var track = currentTrack
    if (!track || !track.albumKey) {
      _tintAlbumKey = ""
      tint = null
      return
    }
    if (_tintAlbumKey === track.albumKey) return
    _tintAlbumKey = track.albumKey
    var cached = _tintCache[track.albumKey]
    if (cached !== undefined) {
      tint = cached
      return
    }
    var albumKey = track.albumKey
    request("/library/metadata/" + albumKey, {}, function (response) {
      var items = PlexApi.metadataList(response)
      var colors = items.length ? PlexApi.ultraBlur(items[0]) : null
      // Bounded like waveCache: radio can visit new albums indefinitely.
      var next = {}
      var keys = Object.keys(root._tintCache)
      for (var i = Math.max(0, keys.length - 60); i < keys.length; i++)
        next[keys[i]] = root._tintCache[keys[i]]
      next[albumKey] = colors
      root._tintCache = next
      if (root._tintAlbumKey === albumKey) root.tint = colors
    }, function () {
      if (root._tintAlbumKey === albumKey) root.tint = null
    })
  }

  // ============================================================== mpv engine

  // A detached supervisor keeps mpv through reloads and stops it when the
  // plugin is disabled or removed from the persisted shell configuration.
  // The launcher exits 0 only once the socket answers, which is when it is
  // safe to connect: a Quickshell Socket that fails once never reconnects,
  // so each attempt gets a fresh object.
  property var ipc: null
  function engineOnline() { return ipc !== null && ipc.connected === true }
  property bool _wantEngine: false

  Process {
    id: engineProcess
    running: false
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (String(line || "").trim() !== "") console.warn("plexamp/engine:", line)
      }
    }
    onExited: function (code) {
      if (!root._wantEngine) root.shutdownEngine()
      else if (code === 0) root.connectEngine()
      else root.playbackError = "could not start mpv"
    }
  }

  Process {
    id: engineStopProcess
    running: false
  }

  function ensureEngine() {
    _wantEngine = true
    if (engineOnline()) return true
    if (!socketPath) {
      playbackError = "XDG_RUNTIME_DIR is unavailable; cannot start mpv"
      return false
    }
    if (!engineProcess.running && engineScript) {
      engineProcess.command = [engineScript, "start", socketPath, String(volume),
        home + "/.config/omarchy/shell.json"]
      engineProcess.running = true
    }
    return false
  }

  function connectEngine() {
    if (!socketPath) return
    if (ipc) ipc.destroy()
    ipc = ipcComponent.createObject(root)
    ipc.connected = true
  }

  Component {
    id: ipcComponent

    Socket {
      id: sock
      path: root.socketPath
      parser: SplitParser {
        splitMarker: "\n"
        onRead: function (line) { root.handleMpvLine(line) }
      }
      onConnectedChanged: {
        if (root.ipc !== sock) return
        if (connected) {
          root.playbackError = ""
          root.observeProperties()
          root.flushPending()
          root.tryRestorePlayback()
        } else {
          root.engineHasFile = false
          root.isPlaying = false
          positionTimer.stop()
        }
      }
    }
  }

  property var _pending: []
  property int _requestSeq: 0
  property var _requests: ({})

  function sendCommand(args, onReply) {
    var payload = { "command": args }
    if (onReply) {
      _requestSeq++
      payload["request_id"] = _requestSeq
      var next = {}
      for (var k in _requests) next[k] = _requests[k]
      next[String(_requestSeq)] = onReply
      _requests = next
    }
    var line = JSON.stringify(payload) + "\n"
    if (engineOnline()) {
      ipc.write(line)
    } else {
      var queued = _pending.slice()
      queued.push(line)
      if (queued.length > 32) queued.shift()
      _pending = queued
      ensureEngine()
    }
  }

  function flushPending() {
    if (!engineOnline() || !_pending.length) return
    var items = _pending
    _pending = []
    for (var i = 0; i < items.length; i++) ipc.write(items[i])
  }

  function observeProperties() {
    sendCommand(["observe_property", 1, "pause"])
    sendCommand(["observe_property", 2, "duration"])
    sendCommand(["observe_property", 3, "volume"])
    sendCommand(["observe_property", 4, "mute"])
    sendCommand(["observe_property", 5, "core-idle"])
    sendCommand(["observe_property", 6, "playlist-pos"])
    sendCommand(["observe_property", 7, "idle-active"])
  }

  function handleMpvLine(line) {
    var text = String(line || "").trim()
    if (!text) return
    var msg = null
    try {
      msg = JSON.parse(text)
    } catch (e) {
      return
    }

    if (msg.request_id !== undefined) {
      var key = String(msg.request_id)
      var handler = _requests[key]
      if (handler) {
        var next = {}
        for (var k in _requests) if (k !== key) next[k] = _requests[k]
        _requests = next
        handler(msg.error === "success" ? msg.data : undefined)
      }
      return
    }

    switch (String(msg.event || "")) {
    case "property-change":
      applyProperty(String(msg.name || ""), msg.data)
      break
    case "end-file":
      // "eof" is a natural finish; "stop"/"redirect" come from us swapping files.
      var reason = String(msg.reason || "")
      if (reason === "error")
        root.playbackError = "could not play " + (currentTrack ? currentTrack.title : "track")
      if (reason === "eof" || reason === "error") {
        // With a track already queued mpv moves on by itself; playlist-pos is
        // what tells us it happened, and the guard covers it never arriving.
        if (root.queuedKey !== "") advanceGuard.restart()
        else root.advance()
      }
      break
    case "file-loaded":
      playbackError = ""
      engineHasFile = true
      positionTimer.restart()
      break
    }
  }

  function applyProperty(name, data) {
    switch (name) {
    case "pause":
      isPlaying = hasTrack && engineHasFile && data === false
      if (isPlaying) positionTimer.restart(); else positionTimer.stop()
      break
    case "duration":
      if (typeof data === "number" && data > 0) duration = data
      break
    case "volume":
      if (typeof data === "number") {
        var v = Math.round(data)
        if (v !== volume) { volume = v; persistState() }
      }
      break
    case "mute":
      muted = data === true
      break
    case "core-idle":
      // True while paused, buffering, or idle; false only while sound plays.
      if (data === false) {
        engineHasFile = true
        isPlaying = hasTrack
        positionTimer.restart()
      }
      break
    case "idle-active":
      // mpv has no file at all: a cold start, or the end of the queue.
      if (data === true) {
        engineHasFile = false
        isPlaying = false
        positionTimer.stop()
      }
      break
    case "playlist-pos":
      // The playlist never holds more than [current, up-next], so mpv landing
      // past 0 means it rolled into the entry we handed it ahead of time.
      if (typeof data === "number" && data > 0 && queuedKey !== "") {
        queuedKey = ""
        advanceGuard.stop()
        if (canNext) {
          queueIndex = queueIndex + 1
          persistPlayback()
          trackStarted()
        }
      }
      break
    }
  }

  Timer {
    id: positionTimer
    interval: 500
    repeat: true
    running: false
    onTriggered: root.sendCommand(["get_property", "time-pos"], function (value) {
      if (typeof value === "number") root.position = value
    })
  }

  // ============================================================== transport

  function playQueue(tracks, index, source, title) {
    if (!tracks || !tracks.length) return
    queue = tracks.slice()
    queueIndex = Math.max(0, Math.min(index || 0, queue.length - 1))
    queueSource = source || ""
    queueTitle = title || ""
    if (queueSource !== "radio") playQueueId = 0
    persistPlayback()
    loadCurrent()
  }

  function playTrack(track) {
    if (!track) return
    playQueue([track], 0, "", "")
  }

  // mpv is handed a two-entry playlist: whatever is playing, plus the track
  // after it. With --prefetch-playlist mpv opens and buffers that second entry
  // while the first is still going, so the changeover costs nothing.
  property string queuedKey: ""

  Timer {
    id: advanceGuard
    interval: 4000
    repeat: false
    onTriggered: {
      // mpv should have moved to the prefetched entry by now. If it hasn't,
      // load the track the ordinary way rather than sitting in silence.
      if (root.queuedKey === "") return
      root.queuedKey = ""
      root.advance()
    }
  }

  function loadCurrent() {
    var track = currentTrack
    if (!track || !track.stream) return
    ensureEngine()
    engineHasFile = false
    queuedKey = ""
    advanceGuard.stop()
    sendCommand(["loadfile", track.stream, "replace"])
    sendCommand(["set_property", "pause", false])
    trackStarted()
  }

  // Everything that has to happen when a track takes over, whether we loaded
  // it ourselves or mpv rolled into it off the prefetched playlist.
  function trackStarted() {
    var track = currentTrack
    if (!track) return
    position = 0
    duration = track.duration || 0
    playbackError = ""
    isPlaying = true
    positionTimer.restart()
    reportProgress("playing")
    requestWaveform()
    requestTint()
    if (queueSource === "radio" && queueIndex >= queue.length - 2) extendRadio()
    queueNext()
  }

  function queueNext() {
    var upNext = (queueIndex >= 0 && queueIndex + 1 < queue.length)
      ? queue[queueIndex + 1] : null
    if (!upNext || !upNext.stream) {
      queuedKey = ""
      return
    }
    if (queuedKey === String(upNext.ratingKey)) return
    queuedKey = String(upNext.ratingKey)
    // Clearing first keeps the playlist from growing past two entries over a
    // long radio session; playlist-clear leaves the playing entry alone.
    sendCommand(["playlist-clear"])
    sendCommand(["loadfile", upNext.stream, "append"])
    prefetchWaveform(upNext)
  }

  function advance() {
    if (canNext) {
      queueIndex = queueIndex + 1
      persistPlayback()
      loadCurrent()
    } else {
      isPlaying = false
      position = 0
      positionTimer.stop()
      reportProgress("stopped")
    }
  }

  function play() {
    if (!hasTrack) return
    if (!engineHasFile) {
      loadCurrent()
      return
    }
    sendCommand(["set_property", "pause", false])
    isPlaying = true
    positionTimer.restart()
    reportProgress("playing")
  }

  function pause() {
    if (!hasTrack) return
    sendCommand(["set_property", "pause", true])
    isPlaying = false
    positionTimer.stop()
    reportProgress("paused")
  }

  function playPause() {
    if (!hasTrack) {
      // Nothing loaded yet: pick up where the listening history left off.
      if (history.length) playQueue(history, 0, "", "History")
      return
    }
    if (isPlaying) pause(); else play()
  }

  function next() {
    if (!canNext) return
    var upNext = queue[queueIndex + 1]
    // The next entry is already open inside mpv, so stepping the playlist
    // skips instantly instead of re-opening the stream from scratch.
    if (queuedKey !== "" && upNext && queuedKey === String(upNext.ratingKey)) {
      advanceGuard.restart()
      sendCommand(["playlist-next", "force"])
      sendCommand(["set_property", "pause", false])
      return
    }
    queueIndex = queueIndex + 1
    persistPlayback()
    loadCurrent()
  }

  // Play a specific entry of the current queue. Only the entry right after the
  // current one is ever prefetched, so anything further along has to be loaded
  // the ordinary way.
  function jumpTo(index) {
    if (index < 0 || index >= queue.length) return
    if (index === queueIndex) {
      seek(0)
      return
    }
    if (index === queueIndex + 1) {
      next()
      return
    }
    queueIndex = index
    persistPlayback()
    loadCurrent()
  }

  function previous() {
    // Restart the track first, like every other player, then step back.
    if (position > 3) {
      seek(0)
      return
    }
    if (canPrevious) {
      queueIndex = queueIndex - 1
      persistPlayback()
      loadCurrent()
    } else {
      seek(0)
    }
  }

  function stop() {
    positionTimer.stop()
    isPlaying = false
    position = 0
    queuedKey = ""
    engineHasFile = false
    advanceGuard.stop()
    if (engineOnline()) sendCommand(["stop"])
    reportProgress("stopped")
  }

  // A regular shell refresh deliberately leaves mpv alone. Signing out is a
  // different lifecycle boundary: close the detached player and its IPC socket
  // so it cannot keep a stream URL/token-bearing playlist in memory.
  function shutdownEngine() {
    _wantEngine = false
    _pending = []
    if (engineOnline()) sendCommand(["quit"])
    // Also cover sign-out racing a launcher or a disconnected QML socket.
    if (engineScript && socketPath && !engineStopProcess.running) {
      engineStopProcess.command = [engineScript, "stop", socketPath]
      engineStopProcess.running = true
    }
  }

  function seek(seconds) {
    if (!hasTrack) return
    var target = Math.max(0, Math.min(seconds, duration || seconds))
    position = target
    sendCommand(["seek", target, "absolute"])
  }

  function seekRelative(delta) {
    if (!hasTrack) return
    seek(position + delta)
  }

  function setVolume(value) {
    var v = Math.max(0, Math.min(100, Math.round(value)))
    volume = v
    sendCommand(["set_property", "volume", v])
    persistState()
  }

  function adjustVolume(delta) {
    setVolume(volume + delta)
  }

  function toggleMute() {
    muted = !muted
    sendCommand(["set_property", "mute", muted])
  }

  // Let Plex know what we're doing so "recently played" stays meaningful.
  function reportProgress(state) {
    if (!ready || !currentTrack || !currentTrack.ratingKey) return
    request("/:/timeline", {
      "ratingKey": currentTrack.ratingKey,
      "key": currentTrack.key,
      "state": state,
      "time": Math.round(position * 1000),
      "duration": Math.round((duration || currentTrack.duration || 0) * 1000)
    }, null, null)
  }

  Timer {
    interval: 10000
    repeat: true
    running: root.isPlaying
    onTriggered: root.reportProgress("playing")
  }

  // ================================================================== state

  property string _savedSectionKey: ""
  property var _savedPlayback: null
  property bool _stateRead: false
  property bool _playbackRestored: false
  property bool _playbackRestoring: false
  property int _playbackRestoreAttempts: 0

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (data && typeof data.volume === "number")
          root.volume = Math.max(0, Math.min(100, Math.round(data.volume)))
        if (data && data.sectionKey) root._savedSectionKey = String(data.sectionKey)
        if (data && data.prefs && typeof data.prefs === "object") root.prefs = data.prefs
        if (data && data.playback && Array.isArray(data.playback.queue))
          root._savedPlayback = root.sanitizePlayback(data.playback)
      } catch (e) {
        // A missing or corrupt state file just means defaults.
      }
      root._stateRead = true
      root.tryRestorePlayback()
    }
    onLoadFailed: {
      root._stateRead = true
      root.tryRestorePlayback()
    }
  }

  property bool _stateLoaded: false

  // The QML service is replaceable, but mpv is not: when a new service comes
  // up after a shell refresh it reconnects to the old IPC socket, restores the
  // queue description for the UI, and asks mpv for the actual playback time.
  // It never calls loadCurrent() here, which is what preserves the song and
  // its exact position.
  function tryRestorePlayback() {
    if (_playbackRestored || _playbackRestoring || !_stateRead || !engineOnline()
        || !_savedPlayback || !ready)
      return
    var saved = _savedPlayback
    if (!saved.queue || !saved.queue.length) {
      _playbackRestored = true
      return
    }
    var keys = []
    for (var i = 0; i < saved.queue.length; i++) {
      var track = saved.queue[i]
      if (track && track.ratingKey) keys.push(String(track.ratingKey))
    }
    if (!keys.length) {
      _playbackRestored = true
      return
    }
    _playbackRestoring = true
    request("/library/metadata/" + keys.join(","), {}, function (detail) {
      root._playbackRestoring = false
      var map = PlexApi.trackMap(root.serverUri, root.serverToken, detail)
      var restored = []
      for (var j = 0; j < saved.queue.length; j++) {
        var key = String(saved.queue[j].ratingKey || "")
        if (map[key]) restored.push(map[key])
      }
      if (!restored.length) {
        root._playbackRestored = true
        return
      }
      root.queue = restored
      root.queueIndex = Math.max(0, Math.min(Number(saved.queueIndex || 0), restored.length - 1))
      root.queueSource = String(saved.queueSource || "")
      root.queueTitle = String(saved.queueTitle || "")
      root.playQueueId = Number(saved.playQueueId || 0)
      root.duration = root.currentTrack ? Number(root.currentTrack.duration || 0) : 0
      root._playbackRestored = true
      root.requestWaveform()
      root.requestTint()
      // A saved queue is UI metadata. Confirm that this live mpv instance has
      // the same stream before claiming audio survived a shell refresh.
      root.sendCommand(["get_property", "path"], function (path) {
        if (!root.currentTrack || String(path || "") !== String(root.currentTrack.stream || "")) {
          root.engineHasFile = false
          root.isPlaying = false
          root.position = 0
          positionTimer.stop()
          return
        }
        root.engineHasFile = true
        root.sendCommand(["get_property", "pause"], function (value) {
          root.isPlaying = root.hasTrack && value === false
          if (root.isPlaying) positionTimer.restart()
        })
        root.sendCommand(["get_property", "time-pos"], function (value) {
          if (typeof value === "number") root.position = value
        })
      })
    }, function () {
      root._playbackRestoring = false
      if (root._playbackRestoreAttempts < 3) {
        root._playbackRestoreAttempts++
        restoreRetry.restart()
      } else {
        root.statusMessage = "Playback continued, but the queue could not be restored"
      }
    })
  }

  Timer {
    id: restoreRetry
    interval: 1500
    repeat: false
    onTriggered: root.tryRestorePlayback()
  }

  function queueReferences(source) {
    var refs = []
    var list = source || []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].ratingKey)
        refs.push({ ratingKey: String(list[i].ratingKey) })
    }
    return refs
  }

  function sanitizePlayback(playback) {
    var saved = playback || {}
    return {
      queue: queueReferences(saved.queue),
      queueIndex: Number(saved.queueIndex || 0),
      queueSource: String(saved.queueSource || ""),
      queueTitle: String(saved.queueTitle || ""),
      playQueueId: Number(saved.playQueueId || 0)
    }
  }

  function stateDocument(playback) {
    return JSON.stringify({
      volume: root.volume,
      sectionKey: root.musicSectionKey || root._savedSectionKey,
      prefs: root.prefs,
      playback: playback
    }, null, 2) + "\n"
  }

  function persistState() {
    if (!_stateLoaded) return
    persistTimer.restart()
  }

  // Queue changes are written immediately. If the shell is refreshed right
  // after a skip or a new play request, the replacement service still has the
  // metadata needed to reconnect to the already-playing mpv instance.
  function persistPlayback() {
    if (!_stateLoaded) return
    persistTimer.stop()
    writeState()
  }

  function writeState() {
    stateFile.setText(stateDocument({
      queue: queueReferences(root.queue),
      queueIndex: root.queueIndex,
      queueSource: root.queueSource,
      queueTitle: root.queueTitle,
      playQueueId: root.playQueueId
    }))
  }

  Timer {
    id: persistTimer
    interval: 800
    repeat: false
    onTriggered: root.writeState()
  }

  // Nothing is written until the private state directory exists.
  Process {
    id: stateDirProcess
    running: false
    command: ["install", "-d", "-m", "700", root.stateDir]
    onExited: root._stateLoaded = true
  }

  Component.onCompleted: {
    stateDirProcess.running = true
    stateFile.reload()
    authFile.reload()
    // Attach to a player left running by a previous shell instance, but never
    // create an idle one simply because the plugin has loaded. The engine
    // vets the socket first, as it does before every other connect.
    if (engineScript && socketPath) {
      attachProcess.command = [engineScript, "check", socketPath]
      attachProcess.running = true
    }
  }

  Process {
    id: attachProcess
    running: false
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (String(line || "").trim() !== "") console.warn("plexamp/engine:", line)
      }
    }
    onExited: function (code) {
      if (code === 0 && !root.ipc) root.connectEngine()
    }
  }

  Component.onDestruction: {
    // The deadline timer dies with this object, so nothing would bound a
    // request left running.
    cancelRequests()
    // The supervisor survives refreshes, and observes disable/removal even
    // after this QML object and the installed helper files have disappeared.
    if (waveProcess.running) waveProcess.signal(15)
  }
}
