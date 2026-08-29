import QtQuick
import Quickshell
import Quickshell.Io
import "PlexApi.js" as PlexApi

// Plexamp service: owns the Plex session, the play queue, and the headless mpv
// process that actually makes sound. The bar widget is a pure view over this.
Item {
  id: root

  // Injected by omarchy-shell when the service is instantiated.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  property var barWidgetRegistry: null
  property var pluginRegistry: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string authScript: pluginDir ? pluginDir + "/bin/plexamp-auth" : ""
  readonly property string waveScript: pluginDir ? pluginDir + "/bin/plexamp-waveform" : ""
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/omarchy/plexamp"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy/plexamp"
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-plexamp.sock"

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

  property int homeLimit: 12
  property int historyLimit: 40

  property var homePlayed: []      // recently played albums
  property var homeAdded: []       // recently added albums
  property var history: []         // recently played tracks, newest first
  property var stations: []        // server-generated radio stations

  // One level of drill-down: album or artist contents, over any tab.
  property string browseMode: ""   // "" | "album" | "artist"
  property string browseTitle: ""
  property var browseTracks: []
  property var browseAlbums: []
  // Artist view, split the way the Plexamp artist page splits it:
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

  signal browseLoaded()
  signal searchLoaded()

  // ============================================================ credentials

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
    if (!text) {
      if (authState !== "linking") authState = "logged-out"
      serverUri = ""
      serverToken = ""
      serverName = ""
      return
    }
    var data = null
    try {
      data = JSON.parse(text)
    } catch (e) {
      authState = "error"
      authError = "credentials file is not valid JSON"
      return
    }
    if (!data || !data.serverUri || !(data.serverToken || data.accountToken)) {
      if (authState !== "linking") authState = "logged-out"
      return
    }
    serverUri = String(data.serverUri)
    serverToken = String(data.serverToken || data.accountToken)
    serverName = String(data.serverName || "Plex")
    machineIdentifier = String(data.machineIdentifier || "")
    clientId = String(data.clientIdentifier || "")
    authError = ""
    pinCode = ""
    pinUrl = ""
    authState = "ready"
    refreshLibrary()
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

  function logout() {
    stop()
    queue = []
    queueIndex = -1
    homePlayed = []
    homeAdded = []
    history = []
    stations = []
    musicSections = []
    musicSectionKey = ""
    clearSearch()
    clearBrowse()
    if (authProcess.running) authProcess.signal(15)
    if (!authScript) return
    logoutProcess.command = [authScript, "logout"]
    logoutProcess.running = true
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
    onExited: {
      root.authState = "logged-out"
      root.serverUri = ""
      root.serverToken = ""
      root.serverName = ""
    }
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

  function apiRequest(method, path, params, onSuccess, onFailure) {
    if (!serverUri || !serverToken) {
      if (onFailure) onFailure("not connected")
      return
    }
    var query = params || {}
    query["X-Plex-Token"] = serverToken
    var target = PlexApi.url(serverUri, path, query)

    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status >= 200 && xhr.status < 300) {
        var parsed = null
        try {
          parsed = JSON.parse(xhr.responseText)
        } catch (e) {
          if (onFailure) onFailure("unreadable response from Plex")
          return
        }
        if (onSuccess) onSuccess(parsed)
      } else if (onFailure) {
        onFailure(xhr.status === 0 ? "could not reach " + root.serverName
                                   : "Plex returned HTTP " + xhr.status)
      }
    }
    xhr.open(method, target)
    xhr.setRequestHeader("Accept", "application/json")
    if (clientId) xhr.setRequestHeader("X-Plex-Client-Identifier", clientId)
    xhr.send()
  }

  function request(path, params, onSuccess, onFailure) {
    apiRequest("GET", path, params, onSuccess, onFailure)
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
    loadRecentlyPlayed()
    loadRecentlyAdded()
    loadHistory()
  }

  function loadRecentlyPlayed() {
    if (!ready || !musicSectionKey) return
    loading = true
    request("/library/sections/" + musicSectionKey + "/all", {
      "type": 9,
      "sort": "lastViewedAt:desc",
      "lastViewedAt>>": 0,
      "X-Plex-Container-Start": 0,
      "X-Plex-Container-Size": homeLimit
    }, function (response) {
      root.homePlayed = PlexApi.albums(root.serverUri, root.serverToken, response)
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
      var next = {}
      for (var k in root._tintCache) next[k] = root._tintCache[k]
      next[albumKey] = colors
      root._tintCache = next
      if (root._tintAlbumKey === albumKey) root.tint = colors
    }, function () {
      if (root._tintAlbumKey === albumKey) root.tint = null
    })
  }

  // ============================================================== mpv engine

  Process {
    id: mpv
    running: false
    command: ["bash", "-c",
      "rm -f \"$1\"; exec mpv --no-video --idle=yes --no-terminal --really-quiet "
      + "--audio-display=no --gapless-audio=yes --keep-open=no "
      + "--cache=yes --prefetch-playlist=yes "
      + "--volume=\"$2\" --input-ipc-server=\"$1\"",
      "plexamp", root.socketPath, String(root.volume)]

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (String(line || "").trim() !== "") console.warn("plexamp/mpv:", line)
      }
    }

    onStarted: connectTimer.restart()
    onExited: function (code) {
      root.isPlaying = false
      ipc.connected = false
      positionTimer.stop()
      if (root._wantEngine) connectTimer.restart()
    }
  }

  property bool _wantEngine: false

  function ensureEngine() {
    _wantEngine = true
    if (!mpv.running) {
      mpv.running = true
      return false
    }
    if (!ipc.connected) {
      connectTimer.restart()
      return false
    }
    return true
  }

  Timer {
    id: connectTimer
    interval: 200
    repeat: true
    running: false
    property int attempts: 0
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      if (ipc.connected) {
        stop()
        return
      }
      if (!mpv.running) {
        if (root._wantEngine) mpv.running = true
        return
      }
      attempts++
      if (attempts > 50) {
        stop()
        root.playbackError = "mpv did not start"
        return
      }
      ipc.connected = true
    }
  }

  Socket {
    id: ipc
    path: root.socketPath
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root.handleMpvLine(line) }
    }
    onConnectedChanged: {
      if (connected) {
        connectTimer.stop()
        root.playbackError = ""
        root.observeProperties()
        root.flushPending()
      } else if (root._wantEngine) {
        root.isPlaying = false
        positionTimer.stop()
        connectTimer.restart()
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
    if (ipc.connected) {
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
    if (!ipc.connected || !_pending.length) return
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
      positionTimer.restart()
      break
    }
  }

  function applyProperty(name, data) {
    switch (name) {
    case "pause":
      isPlaying = hasTrack && data === false
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
      if (data === true && isPlaying) positionTimer.stop()
      else if (data === false && hasTrack) positionTimer.restart()
      break
    case "playlist-pos":
      // The playlist never holds more than [current, up-next], so mpv landing
      // past 0 means it rolled into the entry we handed it ahead of time.
      if (typeof data === "number" && data > 0 && queuedKey !== "") {
        queuedKey = ""
        advanceGuard.stop()
        if (canNext) {
          queueIndex = queueIndex + 1
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
    advanceGuard.stop()
    if (ipc.connected) sendCommand(["stop"])
    reportProgress("stopped")
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
      } catch (e) {
        // A missing or corrupt state file just means defaults.
      }
    }
  }

  property bool _stateLoaded: false

  function persistState() {
    if (!_stateLoaded) return
    persistTimer.restart()
  }

  Timer {
    id: persistTimer
    interval: 800
    repeat: false
    onTriggered: stateFile.setText(JSON.stringify({
      volume: root.volume,
      sectionKey: root.musicSectionKey
    }, null, 2) + "\n")
  }

  Process {
    id: mkdirProcess
    running: false
    command: ["mkdir", "-p", root.stateDir]
    onExited: root._stateLoaded = true
  }

  Component.onCompleted: {
    mkdirProcess.running = true
    stateFile.reload()
    authFile.reload()
  }

  Component.onDestruction: {
    _wantEngine = false
    if (mpv.running) mpv.signal(15)
    if (waveProcess.running) waveProcess.signal(15)
  }
}
