import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PlexApi.js" as PlexApi

// Bar widget + dropdown for the Ampbar plugin. All state lives in Service.qml;
// this file is the view and the keyboard state machine.
Panel {
  id: root
  moduleName: "io.github.kyllan.ampbar"
  ipcTarget: "io.github.kyllan.ampbar"
  manageIpc: false

  readonly property var plex: bar && bar.shell ? bar.shell.serviceFor("io.github.kyllan.ampbar") : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color dimmer: Qt.darker(foreground, 2.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ album tint

  readonly property var tint: plex ? plex.tint : null
  readonly property bool tinted: !!tint && hasTrack

  // Plex's palette is built to sit behind blurred art, so it can be brighter
  // than a panel full of text wants. Pull each corner back toward the theme's
  // popup background until the contrast is safe again.
  function tintColor(hex) {
    var base = Color.popups.background
    if (!hex) return base
    var c = Qt.color(hex)
    var k = 0.55
    return Qt.rgba(c.r * k + base.r * (1 - k),
                   c.g * k + base.g * (1 - k),
                   c.b * k + base.b * (1 - k), 1)
  }

  // The "mini viewer": cover art as large as it will go, plus the few
  // controls you actually reach for when the panel is just a now-playing card.
  property bool mini: false

  // A compact mini viewer starts with either no queue preview or one track.
  // Its Up next header is always expandable, regardless of that preference.
  readonly property bool miniQueueDefault: plex ? plex.pref("miniQueuePreview", false) === true : false
  property bool miniQueueExpanded: false
  onMiniChanged: if (mini) miniQueueExpanded = false

  readonly property var miniUpNext: {
    if (!plex) return []
    var all = plex.upNext
    if (miniQueueExpanded) return all.slice(0, Math.min(all.length, 5))
    return miniQueueDefault ? all.slice(0, 1) : []
  }

  property bool settingsOpen: false

  readonly property bool playing: plex ? plex.isPlaying : false
  readonly property bool hasTrack: plex ? plex.hasTrack : false
  readonly property var track: plex ? plex.currentTrack : null
  readonly property bool ready: plex ? plex.ready : false
  readonly property bool canRadio: plex ? plex.canStartRadio : false
  readonly property string authState: plex ? plex.authState : "unknown"

  // ------------------------------------------------------------ bar button

  // The settings window writes to the service's own prefs file, so that wins;
  // the shell.json entry stays the fallback for anyone configuring the widget
  // from the bar settings instead.
  function option(name, fallback) {
    var fromShell = setting(name, fallback)
    return plex ? plex.pref(name, fromShell) : fromShell
  }

  readonly property bool hideWhenIdle: option("hideWhenIdle", false) === true
  readonly property bool barArt: option("barArt", true) !== false
  readonly property bool showHints: option("showHints", true) !== false
  visible: !hideWhenIdle || hasTrack
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: bar ? bar.barSize : Style.space(27)

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursor = 0
      if (plex && plex.ready && !plex.history.length && !plex.homePlayed.length)
        plex.refreshLibrary()
      if (tab === tabSearch) focusSearch()
    } else {
      searchFocused = false
    }
  }

  onHasTrackChanged: if (!hasTrack) mini = false

  onSettingsChanged: if (plex) plex.historyLimit = Math.max(10, Math.min(200, setting("recentLimit", 40)))
  Component.onCompleted: if (plex) plex.historyLimit = Math.max(10, Math.min(200, setting("recentLimit", 40)))

  // ------------------------------------------------------------------ tabs

  readonly property int tabHome: 0
  readonly property int tabQueue: 1
  readonly property int tabRadio: 2
  readonly property int tabSearch: 3
  property int tab: tabHome

  readonly property var tabNames: ["Home", "Next up", "Radio", "Search"]

  function setTab(index) {
    var next = Math.max(0, Math.min(tabNames.length - 1, index))
    // Reaching for a tab means you want the library, so drop the mini viewer
    // even when the tab itself doesn't change.
    mini = false
    if (next === tab) {
      if (next === tabSearch) focusSearch()
      return
    }
    if (plex) plex.clearBrowse()
    tab = next
    cursor = 0
    cursorActive = false
    if (list) list.positionViewAtBeginning()
    if (tab === tabSearch) focusSearch()
    else searchFocused = false
  }

  // Wraps in both directions, so Tab off the end of Search lands back on Home.
  function cycleTab(direction) {
    var n = tabNames.length
    setTab((tab + (direction || 1) + n) % n)
  }

  // --------------------------------------------------------- cursor model

  property int cursor: 0
  property bool cursorActive: false
  property bool searchFocused: false

  readonly property bool browsing: plex ? plex.browseMode !== "" : false

  readonly property int rowHeight: Style.space(34)
  readonly property int headerHeight: Style.space(22)

  // The dropdown renders one flat list. Section headers are rows too; they
  // just aren't selectable, which keeps cursor movement a plain index walk.
  readonly property var rows: buildRows()

  function pushHeader(out, title, hint) {
    if (out.length) out.push({ kind: "gap" })
    out.push({ kind: "header", title: title, hint: hint || "" })
  }

  function pushItems(out, items, limit) {
    var count = limit ? Math.min(limit, items.length) : items.length
    for (var i = 0; i < count; i++)
      out.push({ kind: items[i].kind || "track", item: items[i], list: items, index: i })
  }

  function buildRows() {
    if (!plex || !plex.ready) return []
    var out = []

    if (plex.browseMode === "album") {
      pushItems(out, plex.browseTracks)
      return out
    }
    if (plex.browseMode === "artist") {
      var groups = plex.browseGroups
      if (!groups.length) {
        pushItems(out, plex.browseAlbums)
        return out
      }
      for (var g = 0; g < groups.length; g++) {
        pushHeader(out, groups[g].title)
        pushItems(out, groups[g].items)
      }
      return out
    }

    if (tab === tabHome) {
      if (plex.homePlayed.length) {
        pushHeader(out, "Most played this month")
        pushItems(out, plex.homePlayed)
      }
      if (plex.homeAdded.length) {
        pushHeader(out, "Recently added")
        pushItems(out, plex.homeAdded)
      }
      if (plex.history.length) {
        pushHeader(out, "History")
        pushItems(out, plex.history)
      }
      return out
    }

    if (tab === tabQueue) {
      if (!plex.queue.length) return out
      if (plex.currentTrack) {
        pushHeader(out, "Now playing")
        out.push({ kind: "track", item: plex.currentTrack, queueAt: plex.queueIndex })
      }
      if (plex.upNext.length) {
        pushHeader(out, plex.queueTitle ? "Next up  ·  " + plex.queueTitle : "Next up")
        for (var q = plex.queueIndex + 1; q < plex.queue.length; q++)
          out.push({ kind: "track", item: plex.queue[q], queueAt: q })
      }
      return out
    }

    if (tab === tabRadio) {
      if (root.track && root.track.artistKey) {
        pushHeader(out, "For what you're playing")
        out.push({
          kind: "station",
          item: {
            kind: "station",
            key: "/library/metadata/" + root.track.artistKey + "/station/1",
            title: root.track.artist + " radio",
            artist: "Similar to this artist",
            art: root.track.art || ""
          }
        })
      }
      if (plex.stations.length) {
        pushHeader(out, plex.musicSectionTitle || "Library")
        pushItems(out, plex.stations)
      }
      return out
    }

    if (plex.searchArtists.length) {
      pushHeader(out, "Artists")
      pushItems(out, plex.searchArtists, 5)
    }
    if (plex.searchAlbums.length) {
      pushHeader(out, "Albums")
      pushItems(out, plex.searchAlbums, 8)
    }
    if (plex.searchTracks.length) {
      pushHeader(out, "Tracks")
      pushItems(out, plex.searchTracks, 12)
    }
    return out
  }

  function rowIsSelectable(row) {
    return !!row && row.kind !== "header" && row.kind !== "gap"
  }

  readonly property real rowsHeight: {
    var total = 0
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "header") total += headerHeight
      else if (rows[i].kind === "gap") total += Style.space(6)
      else total += rowHeight
    }
    return total
  }

  // Enough list to be worth scrolling, never so much that the panel outgrows
  // the screen — KeyboardPanel clamps the final number anyway.
  readonly property real listHeight: Math.max(Style.space(150), Math.min(rowsHeight, Style.space(430)))

  function firstSelectable(from, step) {
    for (var i = from; i >= 0 && i < rows.length; i += step)
      if (rowIsSelectable(rows[i])) return i
    return -1
  }

  // h/Left backs out one level, l/Right drills into the row under the cursor.
  // Seeking lives on , and . instead, so the movement keys mean the same thing
  // here as they do in the mini viewer.
  function moveHorizontal(dx) {
    if (dx < 0) {
      goBack(false)
      return
    }
    if (mini) return
    if (!cursorActive) {
      cursorActive = true
      ensureCursor()
      return
    }
    activateCursor(true)
  }

  function moveCursor(dx, dy) {
    if (dx !== 0) {
      moveHorizontal(dx)
      return
    }
    if (!rows.length) return
    var step = dy > 0 ? 1 : -1
    var next = firstSelectable(cursor + step, step)
    if (next < 0) next = step > 0 ? firstSelectable(0, 1) : firstSelectable(rows.length - 1, -1)
    if (next < 0) return
    cursor = next
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  function ensureCursor() {
    if (rowIsSelectable(rows[cursor])) return
    var at = firstSelectable(cursor, 1)
    if (at < 0) at = firstSelectable(rows.length - 1, -1)
    if (at >= 0) cursor = at
  }

  function activateRow(row) {
    if (!plex || !row) return
    var item = row.item
    if (!item) return
    // Rows built from the live queue jump inside it instead of starting a
    // fresh one, so picking "next up" keeps the rest of the queue intact.
    if (row.queueAt !== undefined) {
      plex.jumpTo(row.queueAt)
    } else if (row.kind === "track") {
      plex.playQueue(row.list || [item], row.index || 0, "", "")
    } else if (row.kind === "album") {
      plex.playAlbum(item.ratingKey, item.title)
    } else if (row.kind === "artist") {
      plex.openArtist(item.ratingKey, item.title)
    } else if (row.kind === "station") {
      plex.playStation(item.key, item.title)
    }
  }

  // Enter plays; Space (and the "open" verb) drills into a container instead.
  function openRow(row) {
    if (!plex || !row) return
    var item = row.item
    if (!item) return
    if (row.kind === "album") plex.openAlbum(item.ratingKey, item.title)
    else if (row.kind === "artist") plex.openArtist(item.ratingKey, item.title)
    else activateRow(row)
  }

  function activateCursor(open) {
    if (!rows.length) return
    var row = rows[Math.max(0, Math.min(cursor, rows.length - 1))]
    if (!rowIsSelectable(row)) return
    if (open) openRow(row); else activateRow(row)
  }

  // `closeAtRoot` is what separates Backspace (which dismisses the panel once
  // there is nothing left to back out of) from h, which just stops.
  function goBack(closeAtRoot) {
    if (!plex) return
    if (mini) {
      mini = false
    } else if (plex.browseMode !== "") {
      plex.clearBrowse()
      cursor = 0
      cursorActive = false
    } else if (tab !== tabHome) {
      setTab(tabHome)
    } else if (closeAtRoot !== false) {
      root.close()
    }
  }

  function openSettings() {
    settingsOpen = true
    root.close()
  }

  function focusSearch() {
    searchFocused = true
    Qt.callLater(function () {
      if (root.searchFocused && searchLoader.item) searchLoader.item.forceActiveFocus()
    })
  }

  // Tab inside the search field has to be handled by the field itself: the key
  // catcher is blocked while it has focus, so the panel never sees the key.
  function tabFromSearch(direction) {
    cycleTab(direction)
    if (tab !== tabSearch) leaveSearch()
  }

  // Enter in the search field commits the query and hands the cursor to the
  // results. Key autorepeat used to deliver a second Return to the panel a
  // few milliseconds later, which opened whichever row the cursor had just
  // landed on — the first artist, every time. This swallows that one.
  property bool swallowReturn: false

  Timer {
    id: returnGuard
    interval: 350
    repeat: false
    onTriggered: root.swallowReturn = false
  }

  function guardReturn() {
    swallowReturn = true
    returnGuard.restart()
  }

  function leaveSearch() {
    searchFocused = false
    cursorActive = rows.length > 0
    ensureCursor()
    keyCatcher.forceActiveFocus()
  }

  Connections {
    target: root.plex
    ignoreUnknownSignals: true
    function onBrowseLoaded() {
      root.mini = false
      root.cursor = 0
      root.cursorActive = true
      root.ensureCursor()
      list.positionViewAtBeginning()
    }
    function onSearchLoaded() {
      root.cursor = 0
      root.ensureCursor()
      list.positionViewAtBeginning()
    }
  }

  // ------------------------------------------------------------------- IPC

  IpcHandler {
    target: root.ipcTarget
    // close/hide also dismiss the settings window: it holds the keyboard
    // exclusively, so "close the plugin" has to mean all of it.
    function open(): void { root.settingsOpen = false; root.open() }
    function close(): void { root.settingsOpen = false; root.close() }
    function show(): void { root.settingsOpen = false; root.open() }
    function hide(): void { root.settingsOpen = false; root.close() }
    function toggle(): void {
      if (root.settingsOpen) { root.settingsOpen = false; return }
      root.toggle()
    }
    function playPause(): string { if (root.plex) root.plex.playPause(); return "ok" }
    function next(): string { if (root.plex) root.plex.next(); return "ok" }
    function previous(): string { if (root.plex) root.plex.previous(); return "ok" }
    function stop(): string { if (root.plex) root.plex.stop(); return "ok" }
    function volumeUp(): string { if (root.plex) root.plex.adjustVolume(5); return "ok" }
    function volumeDown(): string { if (root.plex) root.plex.adjustVolume(-5); return "ok" }
    function radio(): string { if (root.plex) root.plex.radioForCurrentArtist(); return "ok" }
    function artist(): string {
      if (!root.plex) return "unavailable"
      root.mini = false
      root.plex.browseCurrentArtist()
      if (!root.opened) root.open()
      return "ok"
    }
    function album(): string {
      if (!root.plex) return "unavailable"
      root.mini = false
      root.plex.browseCurrentAlbum()
      if (!root.opened) root.open()
      return "ok"
    }
    function queue(): string {
      root.setTab(root.tabQueue)
      root.open()
      return "ok"
    }
    function settings(): string {
      root.openSettings()
      return "ok"
    }
    function mini(): string {
      if (!root.hasTrack) return "nothing playing"
      root.mini = !root.mini
      if (!root.opened) root.open()
      return root.mini ? "mini" : "full"
    }
    function status(): string {
      if (!root.plex) return "unavailable"
      if (!root.plex.ready) return root.plex.authState
      if (!root.plex.hasTrack) return "idle"
      return (root.plex.isPlaying ? "playing: " : "paused: ")
        + root.plex.currentTrack.title + " — " + root.plex.currentTrack.artist
    }
  }

  // --------------------------------------------------------------- the bar

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        id: barIcon

        // A loaded track wears its own cover in the bar. Ampbar's equalizer
        // mark stands in for an idle player, and the bars cover the gap while the art is
        // still in flight (or when the server won't hand it over).
        readonly property string artSource:
          root.barArt && root.hasTrack && root.track ? (root.track.art || "") : ""
        readonly property bool showArt: artSource !== "" && art.status === Image.Ready

        // A rounded clip needs a real mask: `clip` is rectangular, and the art
        // covers the corners of any rounded Rectangle it sits inside.
        Rectangle {
          id: artMask
          anchors.fill: parent
          radius: Style.space(4)
          color: "white"
          visible: false
          layer.enabled: true
        }

        Item {
          anchors.fill: parent
          visible: barIcon.showArt
          // Dimmed while paused, the way the bars used to freeze mid-stride.
          opacity: root.playing ? 1.0 : 0.55
          layer.enabled: true
          layer.smooth: true
          layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: artMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 0.35
          }

          Behavior on opacity { NumberAnimation { duration: 160 } }

          Image {
            id: art
            anchors.fill: parent
            source: barIcon.artSource
            asynchronous: true
            cache: true
            mipmap: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: Style.space(48)
            sourceSize.height: Style.space(48)
          }
        }

        AmpIcon {
          anchors.centerIn: parent
          width: Style.space(12)
          height: Style.space(12)
          visible: !root.hasTrack
          color: Qt.darker(root.barForeground, 1.55)
        }

        SoundBars {
          anchors.centerIn: parent
          width: Style.space(13)
          height: Style.space(12)
          visible: root.hasTrack && !barIcon.showArt
          active: root.playing
          color: root.barForeground
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.plex) root.plex.playPause()
      } else if (buttonCode === Qt.MiddleButton) {
        if (root.plex) root.plex.next()
      } else {
        root.toggle()
      }
    }
  }

  // ---------------------------------------------------------- the dropdown

  PlexPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.mini ? Style.space(300) : Style.space(430))
    contentHeight: panel.fittedContentHeight(
      root.mini ? miniColumn.implicitHeight : column.implicitHeight, Style.space(780))

    tinted: root.tinted
    tintTopLeft: root.tintColor(root.tint ? root.tint.topLeft : "")
    tintTopRight: root.tintColor(root.tint ? root.tint.topRight : "")
    tintBottomLeft: root.tintColor(root.tint ? root.tint.bottomLeft : "")
    tintBottomRight: root.tintColor(root.tint ? root.tint.bottomRight : "")

    Behavior on tintTopLeft { ColorAnimation { duration: 320 } }
    Behavior on tintTopRight { ColorAnimation { duration: 320 } }
    Behavior on tintBottomLeft { ColorAnimation { duration: 320 } }
    Behavior on tintBottomRight { ColorAnimation { duration: 320 } }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field owns input every key must reach it verbatim.
      blocked: root.searchFocused

      onMoveRequested: function (dx, dy) {
        if (dx !== 0) {
          root.moveHorizontal(dx)
          return
        }
        if (root.mini) return
        if (dy !== 0 && !root.cursorActive) {
          root.cursorActive = true
          root.ensureCursor()
          return
        }
        root.moveCursor(dx, dy)
      }
      // Return emits returnRequested *and* activateRequested; Space emits only
      // the latter. The flag is what keeps Return on "play this row" while
      // Space stays play/pause everywhere, mini viewer included.
      property bool sawReturn: false
      onReturnRequested: {
        sawReturn = true
        // A Return left over from committing a search must not play a row.
        if (root.swallowReturn) {
          root.swallowReturn = false
          return
        }
        if (root.mini) {
          if (root.plex) root.plex.playPause()
          return
        }
        if (root.cursorActive) root.activateCursor(false)
      }
      onActivateRequested: {
        if (sawReturn) { sawReturn = false; return }
        if (root.plex) root.plex.playPause()
      }
      onCloseRequested: root.close()
      // PanelKeyCatcher maps x to delete. Nothing here deletes anything, and
      // having x double as "back" alongside h only ever confused things.
      onDeleteRequested: {}
      onTabRequested: function (direction) { root.cycleTab(direction) }
      onTextKey: function (t) {
        if (!root.plex) return
        switch (t) {
        case "1":                 root.setTab(root.tabHome); break
        case "2": case "u":       root.setTab(root.tabQueue); break
        case "3":                 root.setTab(root.tabRadio); break
        case "4": case "/":       root.setTab(root.tabSearch); break
        case "c": case "C":       root.openSettings(); break
        case "?":                 root.plex.setPref("showHints", !root.showHints); break
        case "p":                 root.plex.playPause(); break
        case "n":                 root.plex.next(); break
        case "b":                 root.plex.previous(); break
        case "m":                 root.plex.toggleMute(); break
        case ",":                 root.plex.seekRelative(-5); break
        case ".":                 root.plex.seekRelative(5); break
        case "<":                 root.plex.seekRelative(-30); break
        case ">":                 root.plex.seekRelative(30); break
        case "+": case "=":       root.plex.adjustVolume(5); break
        case "-": case "_":       root.plex.adjustVolume(-5); break
        case "a": case "A":       root.plex.browseCurrentArtist(); break
        case "d": case "D":       root.plex.browseCurrentAlbum(); break
        case "R":                 root.plex.radioForCurrentArtist(); break
        case "r":                 root.mini = false; root.plex.refreshLibrary(); break
        case "v": case "V":       if (root.hasTrack) root.mini = !root.mini; break
        case "L":                 root.mini = false; root.plex.cycleSection(1); break
        case "g":                 root.cursor = 0; root.ensureCursor()
                                  list.positionViewAtBeginning(); break
        case "G":                 root.cursor = Math.max(0, root.rows.length - 1)
                                  root.ensureCursor(); list.positionViewAtEnd(); break
        case "s": case "S":       if (root.authState !== "ready") root.plex.login(); break
        case "O":                 root.plex.logout(); break
        case "\b":                root.goBack(); break
        }
      }

      ColumnLayout {
        id: column
        anchors.fill: parent
        visible: !root.mini
        spacing: Style.space(8)

        // ---------------------------------------------------- signed out --

        Loader {
          Layout.fillWidth: true
          active: root.authState !== "ready"
          visible: active
          sourceComponent: signInBlock
        }

        // ---------------------------------------------------- now playing --

        Loader {
          Layout.fillWidth: true
          active: root.authState === "ready"
          visible: active
          sourceComponent: nowPlayingBlock
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
          visible: root.authState === "ready"
        }

        // ----------------------------------------------------------- tabs --

        RowLayout {
          Layout.fillWidth: true
          visible: root.authState === "ready" && !root.browsing
          spacing: Style.space(4)

          Repeater {
            model: root.tabNames

            delegate: Item {
              id: tabItem
              required property int index
              required property string modelData

              readonly property bool selected: root.tab === index

              Layout.preferredWidth: tabLabel.implicitWidth + Style.space(18)
              Layout.preferredHeight: Style.space(24)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: tabItem.selected
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                  : (tabMouse.containsMouse
                     ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                     : "transparent")
              }

              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: tabItem.modelData
                color: tabItem.selected ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: tabItem.selected
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setTab(tabItem.index)
              }
            }
          }

          Item { Layout.fillWidth: true }

          // Only worth showing when the server actually has more than one.
          Text {
            visible: root.plex && root.plex.musicSections.length > 1
            text: (root.plex ? root.plex.musicSectionTitle : "") + "  ⇅"
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.maximumWidth: Style.space(120)

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.plex) root.plex.cycleSection(1)
            }
          }
        }

        // ------------------------------------------------------ breadcrumb --

        RowLayout {
          Layout.fillWidth: true
          visible: root.browsing
          spacing: Style.space(6)

          PanelSectionHeader {
            Layout.fillWidth: true
            text: root.plex ? root.plex.browseTitle.toUpperCase() : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            elide: Text.ElideRight
          }

          Text {
            text: "h  back"
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goBack()
            }
          }
        }

        // ---------------------------------------------------- search field --

        Loader {
          id: searchLoader
          Layout.fillWidth: true
          active: root.authState === "ready" && root.tab === root.tabSearch && !root.browsing
          visible: active
          sourceComponent: searchField
        }

        // ------------------------------------------------------------ list --

        ListView {
          id: list
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: root.listHeight
          Layout.minimumHeight: Style.space(80)
          visible: root.authState === "ready"
          clip: true
          model: root.rows
          currentIndex: root.cursor
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Item {
            id: rowItem
            required property int index
            required property var modelData

            readonly property string kind: modelData ? modelData.kind : ""
            readonly property var item: modelData ? modelData.item : null
            readonly property bool isTrack: kind === "track"
            readonly property bool selectable: root.rowIsSelectable(modelData)
            readonly property bool hasCursor: root.cursorActive && root.cursor === index && selectable
            readonly property bool isCurrent: root.track && rowItem.isTrack && rowItem.item
              && String(rowItem.item.ratingKey) === String(root.track.ratingKey)

            width: list.width
            height: kind === "header" ? root.headerHeight
                  : (kind === "gap" ? Style.space(6) : root.rowHeight)

            // ---- section header ----
            PanelSectionHeader {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: Style.space(2)
              anchors.bottomMargin: Style.space(3)
              visible: rowItem.kind === "header"
              text: rowItem.modelData && rowItem.modelData.title
                ? String(rowItem.modelData.title).toUpperCase() : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              elide: Text.ElideRight
            }

            // ---- entry ----
            CursorSurface {
              anchors.fill: parent
              anchors.leftMargin: Style.space(2)
              anchors.rightMargin: Style.space(2)
              visible: rowItem.selectable
              hasCursor: rowItem.hasCursor
              current: rowItem.isCurrent
              foreground: root.foreground
              accent: root.accent
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)
              visible: rowItem.selectable

              // Tiny cover thumbnail keeps the list scannable by album.
              Item {
                Layout.preferredWidth: Style.space(24)
                Layout.preferredHeight: Style.space(24)
                Layout.alignment: Qt.AlignVCenter

                Rectangle {
                  anchors.fill: parent
                  radius: rowItem.kind === "artist" ? width / 2 : Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                }

                Image {
                  anchors.fill: parent
                  source: rowItem.item ? (rowItem.item.art || "") : ""
                  asynchronous: true
                  cache: true
                  fillMode: Image.PreserveAspectCrop
                  sourceSize.width: Style.space(48)
                  sourceSize.height: Style.space(48)
                  visible: status === Image.Ready && rowItem.kind !== "station"
                }

                Text {
                  anchors.centerIn: parent
                  visible: rowItem.kind === "station"
                  text: "󰐻"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                SoundBars {
                  anchors.centerIn: parent
                  width: Style.space(12)
                  height: Style.space(12)
                  visible: rowItem.isCurrent && root.playing
                  active: root.playing
                  color: root.accent
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                  Layout.fillWidth: true
                  text: rowItem.item ? rowItem.item.title : ""
                  color: rowItem.isCurrent ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  text: {
                    if (!rowItem.item) return ""
                    if (rowItem.isTrack)
                      return rowItem.item.artist + (rowItem.item.album ? "  ·  " + rowItem.item.album : "")
                    var label = rowItem.item.artist || ""
                    if (rowItem.item.plays)
                      label += (label ? "  ·  " : "") + rowItem.item.plays
                        + (rowItem.item.plays === 1 ? " play" : " plays")
                    return label
                  }
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  visible: text !== ""
                }
              }

              Text {
                Layout.alignment: Qt.AlignVCenter
                text: {
                  if (!rowItem.item) return ""
                  if (rowItem.item.viewedAt) return PlexApi.formatAgo(rowItem.item.viewedAt)
                  if (rowItem.isTrack && rowItem.item.duration > 0)
                    return PlexApi.formatTime(rowItem.item.duration)
                  return rowItem.item.year ? String(rowItem.item.year) : ""
                }
                color: root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              enabled: rowItem.selectable
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onContainsMouseChanged: {
                if (containsMouse) {
                  root.cursorActive = true
                  root.cursor = rowItem.index
                }
              }
              onClicked: function (mouse) {
                root.cursor = rowItem.index
                root.cursorActive = true
                // Right-click opens a container instead of playing it.
                root.activateCursor(mouse.button === Qt.RightButton)
              }
            }
          }

          // Empty states: never leave the list looking broken.
          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: list.count === 0
            text: {
              if (!root.plex) return "Service unavailable"
              if (root.plex.loading || root.plex.searching) return "Loading…"
              if (root.tab === root.tabSearch)
                return root.plex.searchQuery.length < 2
                  ? "Type to search your library"
                  : "Nothing matched “" + root.plex.searchQuery + "”"
              if (root.tab === root.tabQueue) return "The queue is empty — play something first"
              if (root.tab === root.tabRadio) return "No stations on this library"
              if (root.plex.statusMessage) return root.plex.statusMessage
              return "Nothing here yet — press r to refresh"
            }
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // --------------------------------------------------------- footer --

        Text {
          Layout.fillWidth: true
          visible: root.authState === "ready" && root.showHints
          text: {
            if (root.searchFocused) return "↵ search   ↓ results   Esc back to list"
            if (root.browsing) return "jk move   l open   h back   ↵ play   space pause   n/b skip   ,. seek"
            return "jk move   l open   h back   ↵ play   space pause   n/b skip   ,. seek   / search   v mini   c settings"
          }
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 2
        }
      }

      // ------------------------------------------------- mini viewer --

      ColumnLayout {
        id: miniColumn
        anchors.fill: parent
        visible: root.mini
        spacing: Style.space(10)

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: width
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          clip: true

          Image {
            anchors.fill: parent
            source: root.track ? (root.track.artLarge || root.track.art || "") : ""
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: Style.space(600)
            sourceSize.height: Style.space(600)
            visible: status === Image.Ready
          }

          AmpIcon {
            anchors.centerIn: parent
            width: Style.space(48)
            height: Style.space(48)
            visible: !root.hasTrack
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.mini = false
          }
        }

        Text {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignHCenter
          text: root.track ? root.track.title : "Nothing playing"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignHCenter
          text: root.track ? (root.track.artist + (root.track.album ? "  ·  " + root.track.album : "")) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        SeekBar {
          Layout.fillWidth: true
          Layout.preferredHeight: implicitHeight
          plex: root.plex
          foreground: root.foreground
          accent: root.accent
          dimmer: root.dimmer
          fontFamily: root.fontFamily
          waveHeight: Style.space(42)
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          Item { Layout.fillWidth: true }

          PanelActionButton {
            iconText: "󰒮"
            tooltipText: "Previous (b)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.iconLarge
            enabled: root.hasTrack
            onClicked: if (root.plex) root.plex.previous()
          }

          PanelActionButton {
            iconText: root.playing ? "󰏤" : "󰐊"
            tooltipText: root.playing ? "Pause (p)" : "Play (p)"
            foreground: root.foreground
            hoverColor: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.display
            onClicked: if (root.plex) root.plex.playPause()
          }

          PanelActionButton {
            iconText: "󰒭"
            tooltipText: "Next (n)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.iconLarge
            enabled: root.plex ? root.plex.canNext : false
            onClicked: if (root.plex) root.plex.next()
          }

          Item { Layout.fillWidth: true }
        }

        // Volume sits under the transport, so the mini viewer is a complete
        // player rather than a picture with three buttons.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          PanelActionButton {
            iconText: root.plex && root.plex.muted ? "󰝟" : "󰕾"
            tooltipText: "Mute (m)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: if (root.plex) root.plex.toggleMute()
          }

          PanelSlider {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            bar: root.bar
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.plex ? root.plex.volume : 0
            onMoved: function (v) { if (root.plex) root.plex.setVolume(v) }
            onReleased: function (v) { if (root.plex) root.plex.setVolume(v) }
          }

          PanelActionButton {
            iconText: "󰒓"
            tooltipText: "Settings (c)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openSettings()
          }
        }

        // --------------------------------------------------------- up next --

        // The setting chooses whether the collapsed mini viewer shows nothing
        // or one track. The header always reveals more on demand.
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(18)
          visible: root.plex && root.plex.upNext.length > 0

          PanelSectionHeader {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "UP NEXT"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: (root.plex ? root.plex.upNext.length : 0)
              + (root.miniQueueExpanded ? "  ⌃" : "  ⌄")
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.miniQueueExpanded = !root.miniQueueExpanded
          }
        }

        Repeater {
          model: root.miniUpNext

          delegate: Item {
            id: upNextRow
            required property int index
            required property var modelData

            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(28)

            CursorSurface {
              anchors.fill: parent
              hasCursor: upNextMouse.containsMouse
              foreground: root.foreground
              accent: root.accent
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Rectangle {
                Layout.preferredWidth: Style.space(20)
                Layout.preferredHeight: Style.space(20)
                Layout.alignment: Qt.AlignVCenter
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                clip: true

                Image {
                  anchors.fill: parent
                  source: upNextRow.modelData ? (upNextRow.modelData.art || "") : ""
                  asynchronous: true
                  cache: true
                  fillMode: Image.PreserveAspectCrop
                  sourceSize.width: Style.space(40)
                  sourceSize.height: Style.space(40)
                  visible: status === Image.Ready
                }
              }

              Text {
                Layout.fillWidth: true
                text: upNextRow.modelData
                  ? (upNextRow.modelData.title + "  ·  " + upNextRow.modelData.artist) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: upNextMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.plex) root.plex.jumpTo(root.plex.queueIndex + 1 + upNextRow.index)
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.showHints
          horizontalAlignment: Text.AlignHCenter
          text: "h back   ,. seek   space play/pause   n/b skip   u queue"
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Its own layer-shell surface: the dropdown is anchored under the bar
  // button and sized to the list, which is the wrong shape for a settings
  // form. Opening it closes the dropdown so only one surface holds the
  // keyboard at a time.
  PlexSettings {
    plex: root.plex
    anchorItem: button
    open: root.settingsOpen
    foreground: root.foreground
    accent: root.accent
    urgent: root.urgent
    fontFamily: root.fontFamily
    onCloseRequested: root.settingsOpen = false
  }

  // ============================================================ components

  Component {
    id: searchField

    TextField {
      id: queryField
      placeholderText: "Search artists, albums, tracks…"
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      verticalPadding: Style.spacing.controlPaddingY
      text: root.plex ? root.plex.searchQuery : ""

      onActiveFocusChanged: root.searchFocused = activeFocus
      onTextChanged: searchDebounce.restart()
      onAccepted: {
        searchDebounce.stop()
        if (root.plex) root.plex.search(text)
        // Hand the cursor to the results, but not to whatever Return arrives
        // next: autorepeat would otherwise open the first artist outright.
        root.guardReturn()
        root.leaveSearch()
      }
      Keys.onEscapePressed: root.leaveSearch()
      Keys.onDownPressed: root.leaveSearch()
      Keys.onTabPressed: root.tabFromSearch(1)
      Keys.onBacktabPressed: root.tabFromSearch(-1)

      Component.onCompleted: Qt.callLater(forceActiveFocus)

      Timer {
        id: searchDebounce
        interval: 350
        repeat: false
        onTriggered: if (root.plex) root.plex.search(queryField.text)
      }
    }
  }

  Component {
    id: signInBlock

    ColumnLayout {
      spacing: Style.space(10)

      PanelHero {
        Layout.fillWidth: true
        title: "Ampbar for Plex"
        meta: {
          switch (root.authState) {
          case "linking": return "Waiting for you to link this device…"
          case "error":   return root.plex ? root.plex.authError : "Sign-in failed"
          default:        return "Not signed in to Plex"
          }
        }
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          AmpIcon {
            width: Style.font.display
            height: Style.font.display
            color: root.authState === "error" ? root.urgent : root.foreground
          }
        }
      }

      // The PIN the user types at plex.tv/link.
      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: pinColumn.implicitHeight + Style.space(20)
        visible: root.plex && root.plex.pinCode !== ""
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

        ColumnLayout {
          id: pinColumn
          anchors.centerIn: parent
          width: parent.width - Style.space(20)
          spacing: Style.space(4)

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: root.plex ? root.plex.pinCode : ""
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            font.letterSpacing: Style.space(4)
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Enter this code at plex.tv/link"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Button {
        Layout.fillWidth: true
        visible: root.authState !== "linking"
        text: root.authState === "error" ? "Try signing in again" : "Sign in with Plex"
        onClicked: if (root.plex) root.plex.login()
      }

      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        visible: root.authState !== "linking"
        text: "or press s"
        color: root.dimmer
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        visible: root.authState === "linking"
        text: "Esc closes this panel — sign-in keeps running"
        color: root.dimmer
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Component {
    id: nowPlayingBlock

    ColumnLayout {
      spacing: Style.space(8)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)

        // Cover art, or Ampbar's own mark when nothing is loaded.
        Rectangle {
          Layout.preferredWidth: Style.space(64)
          Layout.preferredHeight: Style.space(64)
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          clip: true

          Image {
            anchors.fill: parent
            source: root.track ? (root.track.artLarge || root.track.art || "") : ""
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: Style.space(128)
            sourceSize.height: Style.space(128)
            visible: status === Image.Ready
          }

          AmpIcon {
            anchors.centerIn: parent
            width: Style.space(24)
            height: Style.space(24)
            visible: !root.hasTrack
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
          }

          // Clicking the art swaps to the mini viewer, like tapping the
          // artwork in a music player.
          MouseArea {
            anchors.fill: parent
            enabled: root.hasTrack
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.mini = true

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              visible: parent.containsMouse
              color: Qt.rgba(0, 0, 0, 0.35)

              Text {
                anchors.centerIn: parent
                text: "󰊓"
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.space(2)

          Text {
            Layout.fillWidth: true
            text: root.track ? root.track.title : "Nothing playing"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            text: root.track ? root.track.artist : (root.plex ? root.plex.serverName : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            text: {
              if (!root.track) return ""
              var suffix = root.plex && root.plex.queueSource === "radio" && root.plex.queueTitle
                ? "   ·   " + root.plex.queueTitle : ""
              return root.track.album + suffix
            }
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            visible: text !== ""
          }
        }
      }

      // ------------------------------------------------------- progress --

      SeekBar {
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
        visible: root.hasTrack
        plex: root.plex
        foreground: root.foreground
        accent: root.accent
        dimmer: root.dimmer
        fontFamily: root.fontFamily
        waveHeight: Style.space(30)
      }

      // ------------------------------------------------------ transport --

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        PanelActionButton {
          iconText: "󰒮"
          tooltipText: "Previous (b)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: root.hasTrack
          onClicked: if (root.plex) root.plex.previous()
        }

        PanelActionButton {
          iconText: root.playing ? "󰏤" : "󰐊"
          tooltipText: root.playing ? "Pause (p)" : "Play (p)"
          foreground: root.foreground
          hoverColor: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.iconLarge
          onClicked: if (root.plex) root.plex.playPause()
        }

        PanelActionButton {
          iconText: "󰒭"
          tooltipText: "Next (n)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: root.plex ? root.plex.canNext : false
          onClicked: if (root.plex) root.plex.next()
        }

        PanelActionButton {
          iconText: "󰐻"
          enabled: root.canRadio
          // Dimmed text alone is easy to miss on a tinted panel, so the whole
          // button fades when there is nothing for it to seed from.
          opacity: enabled ? 1.0 : 0.4
          tooltipText: enabled
            ? (root.hasTrack ? "Radio from this artist (R)" : "Start library radio (R)")
            : "No radio for this track"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (root.plex) root.plex.radioForCurrentArtist()

          Behavior on opacity { NumberAnimation { duration: 120 } }
        }

        Item { Layout.preferredWidth: Style.space(6) }

        PanelActionButton {
          iconText: "󰒓"
          tooltipText: "Settings (c)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openSettings()
        }

        PanelActionButton {
          iconText: root.plex && root.plex.muted ? "󰝟" : "󰕾"
          tooltipText: "Mute (m)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (root.plex) root.plex.toggleMute()
        }

        PanelSlider {
          Layout.fillWidth: true
          Layout.minimumWidth: Style.space(90)
          Layout.alignment: Qt.AlignVCenter
          bar: root.bar
          minimum: 0
          maximum: 100
          step: 5
          integer: true
          value: root.plex ? root.plex.volume : 0
          onMoved: function (v) { if (root.plex) root.plex.setVolume(v) }
          onReleased: function (v) { if (root.plex) root.plex.setVolume(v) }
        }
      }

      // Drill-down affordances for the current track.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)
        visible: root.hasTrack && !root.browsing

        Text {
          text: "a  more from " + (root.track ? root.track.artist : "")
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.fillWidth: true

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.plex) root.plex.browseCurrentArtist()
          }
        }

        Text {
          text: "d  this album"
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          visible: root.track && root.track.albumKey !== ""

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.plex) root.plex.browseCurrentAlbum()
          }
        }
      }
    }
  }
}
