.pragma library

// URL + response helpers for the Plex Media Server HTTP API.
// Everything here is pure: no network, no QML types, so it stays testable.

function joinUrl(base, path) {
    if (!base)
        return "";
    var b = String(base).replace(/\/+$/, "");
    var p = String(path || "");
    if (p.length && p.charAt(0) !== "/")
        p = "/" + p;
    return b + p;
}

function encodeParams(params) {
    var parts = [];
    for (var key in params) {
        var value = params[key];
        if (value === undefined || value === null || value === "")
            continue;
        parts.push(encodeURIComponent(key) + "=" + encodeURIComponent(value));
    }
    return parts.join("&");
}

function url(base, path, params) {
    var full = joinUrl(base, path);
    var query = encodeParams(params || {});
    if (!query.length)
        return full;
    return full + (full.indexOf("?") >= 0 ? "&" : "?") + query;
}

// Cover art, resized server-side so we never pull a 2000px jpeg into the bar.
function artUrl(base, token, thumb, size) {
    if (!base || !thumb)
        return "";
    var px = size || 300;
    // The transcoder wants a server-relative path, token and all, as its `url`.
    var path = String(thumb);
    if (path.charAt(0) !== "/")
        path = "/" + path;
    var inner = path + (path.indexOf("?") >= 0 ? "&" : "?")
              + "X-Plex-Token=" + encodeURIComponent(token || "");
    return url(base, "/photo/:/transcode", {
        "width": px,
        "height": px,
        "minSize": 1,
        "upscale": 1,
        "url": inner,
        "X-Plex-Token": token
    });
}

// ------------------------------------------------------------------ parsing --

function container(response) {
    if (!response)
        return {};
    return response.MediaContainer || {};
}

function metadataList(response) {
    var mc = container(response);
    var list = mc.Metadata || mc.Directory || mc.Hub || [];
    return Array.isArray(list) ? list : [list];
}

function hubs(response) {
    var list = container(response).Hub || [];
    return Array.isArray(list) ? list : [list];
}

function hubItems(hub) {
    var list = (hub && hub.Metadata) || [];
    return Array.isArray(list) ? list : [list];
}

// Absolute stream URL for the first media part of a track.
function partUrl(base, token, item) {
    if (!item || !item.Media || !item.Media.length)
        return "";
    var media = item.Media[0];
    if (!media.Part || !media.Part.length)
        return "";
    var key = media.Part[0].key;
    if (!key)
        return "";
    return url(base, key, { "X-Plex-Token": token });
}

function track(base, token, item) {
    if (!item)
        return null;
    var thumb = item.thumb || item.parentThumb || item.grandparentThumb || "";
    return {
        kind: "track",
        key: item.key || "",
        ratingKey: String(item.ratingKey || ""),
        title: item.title || "Unknown track",
        artist: item.grandparentTitle || item.originalTitle || "Unknown artist",
        album: item.parentTitle || "",
        artistKey: item.grandparentRatingKey ? String(item.grandparentRatingKey) : "",
        albumKey: item.parentRatingKey ? String(item.parentRatingKey) : "",
        duration: Number(item.duration || 0) / 1000,
        index: Number(item.index || 0),
        thumb: thumb,
        art: artUrl(base, token, thumb, 300),
        artLarge: artUrl(base, token, thumb, 600),
        stream: partUrl(base, token, item)
    };
}

function tracks(base, token, response) {
    var out = [];
    var items = metadataList(response);
    for (var i = 0; i < items.length; i++) {
        var t = track(base, token, items[i]);
        if (t && t.stream)
            out.push(t);
    }
    return out;
}

// ratingKey -> track, for resolving playable media behind a list (history,
// search) whose entries arrive without a Media/Part section.
function trackMap(base, token, response) {
    var map = {};
    var items = metadataList(response);
    for (var i = 0; i < items.length; i++) {
        var t = track(base, token, items[i]);
        if (t && t.ratingKey && t.stream)
            map[t.ratingKey] = t;
    }
    return map;
}

function album(base, token, item) {
    if (!item)
        return null;
    var thumb = item.thumb || item.parentThumb || "";
    return {
        kind: "album",
        ratingKey: String(item.ratingKey || ""),
        title: item.title || "Unknown album",
        artist: item.parentTitle || item.grandparentTitle || "",
        artistKey: item.parentRatingKey ? String(item.parentRatingKey) : "",
        year: item.year || "",
        lastViewedAt: Number(item.lastViewedAt || 0),
        addedAt: Number(item.addedAt || 0),
        art: artUrl(base, token, thumb, 200),
        type: "album"
    };
}

function albums(base, token, response) {
    return albumsFrom(base, token, metadataList(response));
}

function albumsFrom(base, token, items) {
    var out = [];
    for (var i = 0; i < items.length; i++) {
        if (items[i] && items[i].type && items[i].type !== "album")
            continue;
        var a = album(base, token, items[i]);
        if (a && a.ratingKey)
            out.push(a);
    }
    return out;
}

function artist(base, token, item) {
    if (!item)
        return null;
    return {
        kind: "artist",
        ratingKey: String(item.ratingKey || ""),
        title: item.title || "Unknown artist",
        artist: "",
        art: artUrl(base, token, item.thumb || "", 200),
        type: "artist"
    };
}

function artistsFrom(base, token, items) {
    var out = [];
    for (var i = 0; i < items.length; i++) {
        var a = artist(base, token, items[i]);
        if (a && a.ratingKey)
            out.push(a);
    }
    return out;
}

function artists(base, token, response) {
    return artistsFrom(base, token, metadataList(response));
}

// Music library sections only — Plex calls them type "artist".
function musicSections(response) {
    var out = [];
    var items = metadataList(response);
    for (var i = 0; i < items.length; i++) {
        var d = items[i];
        if (d && d.type === "artist" && d.key)
            out.push({ key: String(d.key), title: d.title || "Music", size: 0 });
    }
    return out;
}

// ------------------------------------------------------------------- home --

// /status/sessions/history/all rows. These carry titles and artwork but no
// Media, so the caller resolves `ratingKey` against trackMap() before playing.
function historyEntries(response) {
    var out = [];
    var items = metadataList(response);
    for (var i = 0; i < items.length; i++) {
        var item = items[i];
        if (!item || item.type !== "track" || !item.ratingKey)
            continue;
        // History rows report a track-level thumb that the server 404s on;
        // the album's art is the one that actually resolves.
        var thumb = item.parentThumb || item.grandparentThumb || item.thumb || "";
        out.push({
            kind: "track",
            ratingKey: String(item.ratingKey),
            title: item.title || "Unknown track",
            artist: item.grandparentTitle || "Unknown artist",
            album: item.parentTitle || "",
            artistKey: item.grandparentRatingKey ? String(item.grandparentRatingKey) : "",
            albumKey: item.parentRatingKey ? String(item.parentRatingKey) : "",
            thumb: thumb,
            viewedAt: Number(item.viewedAt || 0),
            duration: 0,
            stream: ""
        });
    }
    return out;
}

// Fill in art + stream for history rows from a resolved ratingKey -> track map.
function resolveHistory(base, token, entries, map) {
    var out = [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var resolved = map[e.ratingKey];
        if (!resolved)
            continue;
        out.push({
            kind: "track",
            key: resolved.key,
            ratingKey: e.ratingKey,
            title: e.title || resolved.title,
            artist: e.artist || resolved.artist,
            album: e.album || resolved.album,
            artistKey: e.artistKey || resolved.artistKey,
            albumKey: e.albumKey || resolved.albumKey,
            duration: resolved.duration,
            index: resolved.index,
            thumb: resolved.thumb || e.thumb,
            art: artUrl(base, token, resolved.thumb || e.thumb, 200),
            artLarge: resolved.artLarge,
            stream: resolved.stream,
            viewedAt: e.viewedAt
        });
    }
    return out;
}

// Plex's history endpoint is track-based. For Home, turn this month's plays
// into the things people actually choose to put on: albums first, with a
// seedable artist-radio fallback for entries that have no album parent.
// `entries` is newest-first, so latestSeen also makes a stable tie-breaker.
function mostPlayedThisMonth(base, token, entries, monthStart, limit) {
    var buckets = {};
    var ordered = [];
    var start = Number(monthStart || 0);
    for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (!entry || Number(entry.viewedAt || 0) < start)
            continue;

        var albumKey = String(entry.albumKey || "");
        var artistKey = String(entry.artistKey || "");
        var kind = albumKey ? "album" : (artistKey ? "station" : "");
        var ratingKey = albumKey || artistKey;
        if (!kind || !ratingKey)
            continue;

        var id = kind + ":" + ratingKey;
        var bucket = buckets[id];
        if (!bucket) {
            bucket = {
                kind: kind,
                ratingKey: ratingKey,
                title: kind === "album" ? (entry.album || "Unknown album")
                                         : ((entry.artist || "Radio picks") + " radio"),
                artist: kind === "album" ? (entry.artist || "") : "Radio / single tracks",
                art: artUrl(base, token, entry.thumb || "", 200),
                key: kind === "station"
                  ? ("/library/metadata/" + artistKey + "/station/1") : "",
                plays: 0,
                latestSeen: 0
            };
            buckets[id] = bucket;
            ordered.push(bucket);
        }
        bucket.plays++;
        bucket.latestSeen = Math.max(bucket.latestSeen, Number(entry.viewedAt || 0));
    }

    ordered.sort(function (a, b) {
        if (b.plays !== a.plays)
            return b.plays - a.plays;
        return b.latestSeen - a.latestSeen;
    });
    return ordered.slice(0, Math.max(0, Number(limit || 5)));
}

// Unique ratingKeys, in first-seen order, for a batched /library/metadata call.
function uniqueKeys(entries) {
    var seen = {};
    var out = [];
    for (var i = 0; i < entries.length; i++) {
        var k = entries[i] && entries[i].ratingKey;
        if (!k || seen[k])
            continue;
        seen[k] = true;
        out.push(k);
    }
    return out;
}

// ------------------------------------------------------------------ radio --

// The station hub is only present when the request asked for includeStations.
function stations(response) {
    var out = [];
    var list = hubs(response);
    for (var i = 0; i < list.length; i++) {
        var hub = list[i];
        if (!hub || hub.type !== "station")
            continue;
        var items = hubItems(hub);
        for (var j = 0; j < items.length; j++) {
            var s = items[j];
            if (!s || !s.key)
                continue;
            out.push({
                kind: "station",
                key: String(s.key),
                ratingKey: String(s.key),
                title: s.title || "Radio",
                artist: "",
                art: ""
            });
        }
    }
    return out;
}

// A play-queue source URI. Plex addresses everything on a server this way.
function stationUri(machineIdentifier, key) {
    if (!machineIdentifier || !key)
        return "";
    var path = String(key);
    if (path.charAt(0) !== "/")
        path = "/" + path;
    return "server://" + machineIdentifier + "/com.plexapp.plugins.library" + path;
}

// ----------------------------------------------------------------- search --

function searchResults(base, token, response) {
    var out = { tracks: [], albums: [], artists: [] };
    var list = hubs(response);
    for (var i = 0; i < list.length; i++) {
        var hub = list[i];
        if (!hub)
            continue;
        var items = hubItems(hub);
        if (hub.type === "track") {
            for (var j = 0; j < items.length; j++) {
                var t = track(base, token, items[j]);
                if (t && t.stream)
                    out.tracks.push(t);
            }
        } else if (hub.type === "album") {
            out.albums = out.albums.concat(albumsFrom(base, token, items));
        } else if (hub.type === "artist") {
            out.artists = out.artists.concat(artistsFrom(base, token, items));
        }
    }
    return out;
}

// ----------------------------------------------------------------- display --

function formatTime(seconds) {
    var s = Math.max(0, Math.floor(Number(seconds) || 0));
    var m = Math.floor(s / 60);
    var h = Math.floor(m / 60);
    var pad = function (n) { return n < 10 ? "0" + n : String(n); };
    if (h > 0)
        return h + ":" + pad(m % 60) + ":" + pad(s % 60);
    return m + ":" + pad(s % 60);
}

// Coarse "when did I play this" label for the history list.
function formatAgo(unixSeconds, nowSeconds) {
    var t = Number(unixSeconds || 0);
    if (t <= 0)
        return "";
    var now = Number(nowSeconds || (Date.now() / 1000));
    var d = Math.max(0, now - t);
    if (d < 90)
        return "now";
    if (d < 3600)
        return Math.round(d / 60) + "m";
    if (d < 86400)
        return Math.round(d / 3600) + "h";
    if (d < 86400 * 7)
        return Math.round(d / 86400) + "d";
    return Math.round(d / (86400 * 7)) + "w";
}

// ------------------------------------------------------------- album tint --

// Plex exposes a four-corner palette per album; Ampbar paints it behind the
// player and so do we. Values are bare hex triples, no leading '#'.
function ultraBlur(item) {
    var colors = item && item.UltraBlurColors;
    if (!colors)
        return null;
    var hex = function (value, fallback) {
        var text = String(value || "").replace(/^#/, "");
        return /^[0-9a-fA-F]{6}$/.test(text) ? "#" + text : fallback;
    };
    var topLeft = hex(colors.topLeft, "");
    if (!topLeft)
        return null;
    return {
        topLeft: topLeft,
        topRight: hex(colors.topRight, topLeft),
        bottomLeft: hex(colors.bottomLeft, topLeft),
        bottomRight: hex(colors.bottomRight, topLeft)
    };
}

// ------------------------------------------------------------ artist view --

// /library/metadata/{artist}/allLeaves in one request gives us every track,
// which is the cheapest way to learn how long each album is. The per-album
// leafCount is only present when an album is fetched on its own.
function trackCountsByAlbum(response) {
    var counts = {};
    var items = metadataList(response);
    for (var i = 0; i < items.length; i++) {
        var parent = items[i] && items[i].parentRatingKey;
        if (!parent)
            continue;
        var key = String(parent);
        counts[key] = (counts[key] || 0) + 1;
    }
    return counts;
}

// An artist's /children only lists releases they are the *album* artist of.
// Tracks on compilations and other artists' records show up in /allLeaves and
// nowhere else, so rebuild those releases from the parent fields on the tracks.
function albumsFromLeaves(base, token, response, exclude) {
    var seen = exclude || {};
    var out = [];
    var items = metadataList(response);
    for (var i = 0; i < items.length; i++) {
        var item = items[i];
        var key = item && item.parentRatingKey ? String(item.parentRatingKey) : "";
        if (!key || seen[key])
            continue;
        seen[key] = true;
        out.push({
            kind: "album",
            ratingKey: key,
            title: item.parentTitle || "Unknown album",
            artist: item.grandparentTitle || "",
            artistKey: item.grandparentRatingKey ? String(item.grandparentRatingKey) : "",
            year: item.parentYear || "",
            art: artUrl(base, token, item.parentThumb || item.thumb || "", 200),
            type: "album"
        });
    }
    return out;
}

var SIDE_RELEASE = /\b(live|in concert|compilation|greatest hits|the best of|remix|remixes|demo|demos|b[- ]sides?|rarities|soundtrack|session|sessions|instrumental|karaoke|acoustic version)\b/i;

// Albums proper first, then short releases, then everything that reads like a
// side release — a useful shape for the artist browser.
function groupArtistAlbums(items, counts, singleMax) {
    var limit = singleMax || 6;
    var main = [];
    var singles = [];
    var other = [];
    for (var i = 0; i < items.length; i++) {
        var entry = items[i];
        var count = counts ? Number(counts[String(entry.ratingKey)] || 0) : 0;
        entry.trackCount = count;
        if (SIDE_RELEASE.test(entry.title || ""))
            other.push(entry);
        else if (count > 0 && count <= limit)
            singles.push(entry);
        else
            main.push(entry);
    }
    return { main: main, singles: singles, other: other };
}
