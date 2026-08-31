import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Floating settings window for the Ampbar plugin. It is its own layer-shell
// surface rather than another page inside the dropdown, so it can be as tall
// as it needs to be and keeps the dropdown's keyboard map intact.
//
// Everything here writes through Service.setPref() except the server address,
// which goes to bin/plexamp-auth — the token never leaves that script.
PanelWindow {
  id: root

  required property var plex
  // Which output to float over. The bar button's own window, so the settings
  // land on the monitor the panel was opened from.
  property Item anchorItem: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool open: false

  signal closeRequested()

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color dimmer: Qt.darker(foreground, 2.1)

  visible: open
  screen: anchorItem && anchorItem.QsWindow.window ? anchorItem.QsWindow.window.screen : null
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }

  WlrLayershell.namespace: "omarchy-ampbar-settings"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // ------------------------------------------------------------- row model

  // One flat list again, the same shape the dropdown uses: an index walk with
  // j/k, and Enter acting on whatever the cursor is sitting on.
  readonly property int rowServer: 0
  readonly property int rowRedetect: 1
  readonly property int rowHints: 2
  readonly property int rowBarArt: 3
  readonly property int rowHideIdle: 4
  readonly property int rowMiniQueuePreview: 5
  readonly property int rowSignOut: 6
  readonly property int rowCount: 7

  property int cursor: 0
  property bool editingServer: false

  // The window is instantiated hidden, so focus has to be re-taken once the
  // surface is actually mapped.
  onOpenChanged: {
    if (!open) {
      editingServer = false
      return
    }
    cursor = 0
    serverField.text = plex ? plex.serverUri : ""
    // Plex direct URLs are long; show the start of one, not its tail.
    serverField.cursorPosition = 0
    Qt.callLater(function () {
      if (root.open) keys.forceActiveFocus()
    })
  }

  function moveCursor(step) {
    cursor = (cursor + step + rowCount) % rowCount
  }

  function toggleOn(name, fallback) {
    if (!plex) return
    plex.setPref(name, !(plex.pref(name, fallback) !== false))
  }

  function toggleOff(name) {
    if (!plex) return
    plex.setPref(name, !(plex.pref(name, false) === true))
  }

  function activate() {
    if (!plex) return
    switch (cursor) {
    case rowServer:
      editingServer = true
      serverField.forceActiveFocus()
      break
    case rowRedetect:   plex.rediscoverServer(); break
    case rowHints:      toggleOn("showHints", true); break
    case rowBarArt:     toggleOn("barArt", true); break
    case rowHideIdle:   toggleOff("hideWhenIdle"); break
    case rowMiniQueuePreview:  toggleOff("miniQueuePreview"); break
    case rowSignOut:
      plex.logout()
      root.closeRequested()
      break
    }
  }

  function commitServer() {
    editingServer = false
    keys.forceActiveFocus()
    if (plex && serverField.text.trim() !== "") plex.setServer(serverField.text)
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.6)

    MouseArea {
      anchors.fill: parent
      onClicked: root.closeRequested()
    }
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function (event) {
      // While the address is being typed every key belongs to the field.
      if (root.editingServer) return
      if (event.key === Qt.Key_Escape) {
        root.closeRequested(); event.accepted = true; return
      }
      if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || event.text === "j") {
        root.moveCursor(1); event.accepted = true; return
      }
      if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || event.text === "k") {
        root.moveCursor(-1); event.accepted = true; return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          || event.key === Qt.Key_Space || event.key === Qt.Key_Right || event.text === "l") {
        root.activate(); event.accepted = true; return
      }
      if (event.key === Qt.Key_Left || event.text === "h") {
        root.closeRequested(); event.accepted = true
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(48), Style.space(430))
      height: Math.min(parent.height - Style.space(48),
                       content.implicitHeight + card.contentTopInset + card.contentBottomInset)
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border,
                                     Math.max(1, Style.space(2)))
      padding: Style.space(18)

      // Clicks inside the card must not reach the dismissing scrim behind it.
      MouseArea { anchors.fill: parent }

      ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Ampbar for Plex settings"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }

          Text {
            text: "Esc"
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeRequested()
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        // --------------------------------------------------------- server --

        PanelSectionHeader {
          Layout.fillWidth: true
          text: "SERVER"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          Layout.fillWidth: true
          text: {
            if (!root.plex) return ""
            if (root.plex.serverBusy) return "Checking that address…"
            if (root.plex.authError) return root.plex.authError
            return root.plex.serverName
              ? ("Connected to " + root.plex.serverName)
              : "Not signed in"
          }
          color: root.plex && root.plex.authError ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        TextField {
          id: serverField
          Layout.fillWidth: true
          placeholderText: "192.168.1.10:32400"
          hasCursor: root.cursor === root.rowServer
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          enabled: root.plex && !root.plex.serverBusy

          onActiveFocusChanged: root.editingServer = activeFocus
          onAccepted: root.commitServer()
          Keys.onEscapePressed: {
            text = root.plex ? root.plex.serverUri : ""
            root.editingServer = false
            keys.forceActiveFocus()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            text: "Use this address"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            enabled: root.plex && !root.plex.serverBusy
            onClicked: root.commitServer()
          }

          Button {
            text: "Detect automatically"
            bordered: true
            hasCursor: root.cursor === root.rowRedetect
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            enabled: root.plex && !root.plex.serverBusy
            onClicked: if (root.plex) root.plex.rediscoverServer()
          }

          Item { Layout.fillWidth: true }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        // ---------------------------------------------------------- panel --

        PanelSectionHeader {
          Layout.fillWidth: true
          text: "PANEL"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Toggle {
          Layout.fillWidth: true
          label: "Show keyboard shortcuts"
          description: "The hint line along the bottom of the panel"
          checked: root.plex ? root.plex.pref("showHints", true) !== false : true
          hasCursor: root.cursor === root.rowHints
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.toggleOn("showHints", true)
        }

        Toggle {
          Layout.fillWidth: true
          label: "Album cover in the bar"
          description: "Off falls back to the animated sound bars"
          checked: root.plex ? root.plex.pref("barArt", true) !== false : true
          hasCursor: root.cursor === root.rowBarArt
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.toggleOn("barArt", true)
        }

        Toggle {
          Layout.fillWidth: true
          label: "Hide the widget when idle"
          description: "The bar button disappears while nothing is loaded"
          checked: root.plex ? root.plex.pref("hideWhenIdle", false) === true : false
          hasCursor: root.cursor === root.rowHideIdle
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.toggleOff("hideWhenIdle")
        }

        Toggle {
          Layout.fillWidth: true
          label: "Show one next-up track in the mini viewer"
          description: "Off starts with no preview; Up next always expands on demand"
          checked: root.plex ? root.plex.pref("miniQueuePreview", false) === true : false
          hasCursor: root.cursor === root.rowMiniQueuePreview
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.toggleOff("miniQueuePreview")
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        // -------------------------------------------------------- account --

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            text: "Sign out of Plex"
            bordered: true
            hasCursor: root.cursor === root.rowSignOut
            foreground: root.urgent
            accent: root.urgent
            fontFamily: root.fontFamily
            enabled: root.plex && root.plex.authState === "ready"
            onClicked: {
              if (root.plex) root.plex.logout()
              root.closeRequested()
            }
          }

          Item { Layout.fillWidth: true }
        }

        Text {
          Layout.fillWidth: true
          text: "jk move   ↵ change   Esc close"
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
