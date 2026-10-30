import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Droidspaces bar widget and panel.
//
// Droidspaces needs root for status and every action, so the widget talks to
// a long-lived root bridge (bin/droidspaces-bridge) launched through pkexec.
// One authentication per shell session feeds the bar, the list and every
// action afterwards; the bridge exits when the shell does.
Panel {
  id: root

  moduleName: "local.droidspaces"
  ipcTarget: "local.droidspaces"

  // ---- helper state -------------------------------------------------
  property var snapshot: null
  property var containers: []
  property bool helperWanted: false
  property bool connected: false
  property bool connecting: false
  property bool quitting: false
  property string helperError: ""
  property string notice: ""
  property bool noticeIsError: false
  property var pending: ({})
  property int reqSeq: 0

  // ---- panel state --------------------------------------------------
  property int cursor: -1
  property string selectedName: ""

  // ---- theme --------------------------------------------------------
  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.45)
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent

  readonly property int runningCount: snapshot ? (Number(snapshot.running_count) || 0) : 0
  readonly property int totalCount: snapshot ? (Number(snapshot.total) || 0) : 0
  readonly property real ramUsedKb: snapshot ? (Number(snapshot.ram_used_kb) || 0) : 0
  readonly property var host: snapshot && snapshot.host ? snapshot.host : ({})
  readonly property bool available: !snapshot || snapshot.available !== false
  readonly property string stateError: snapshot ? String(snapshot.error || "") : ""

  readonly property string barIcon: "\u{f01a6}"

  function settingBool(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null || value === "") return fallback
    if (typeof value === "string") return value !== "false" && value !== "0"
    return !!value
  }

  readonly property bool showCount: settingBool("showCount", true)
  readonly property bool connectOnStartup: settingBool("connectOnStartup", false)

  readonly property string barText: barIcon + (showCount && snapshot
    ? " " + runningCount + (totalCount !== runningCount ? "/" + totalCount : "")
    : "")

  readonly property string barTooltip: {
    if (!snapshot) return "Droidspaces · click to connect"
    var lines = [runningCount + " running · " + totalCount + " total"]
    for (var i = 0; i < containers.length && i < 8; i++) {
      var c = containers[i]
      lines.push((c.running ? "● " : "○ ") + String(c.name || ""))
    }
    if (containers.length > 8) lines.push("…")
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- formatting ---------------------------------------------------
  function fmtKB(kb) {
    var v = Number(kb) || 0
    if (v <= 0) return "0"
    if (v < 1024) return Math.round(v) + "K"
    if (v < 1024 * 1024) return (v / 1024 < 10 ? (Math.round(v / 102.4) / 10) : Math.round(v / 1024)) + "M"
    return (v / 1048576 < 10 ? (Math.round(v / 104857.6) / 10) : Math.round(v / 1048576)) + "G"
  }

  function containerByName(name) {
    for (var i = 0; i < containers.length; i++)
      if (String(containers[i].name || "") === String(name)) return containers[i]
    return null
  }

  // ---- helper protocol ---------------------------------------------
  function send(message) {
    if (!helper.running) return false
    try {
      return helper.write(JSON.stringify(message) + "\n")
    } catch (e) {
      return false
    }
  }

  function sendWatch() {
    if (root.connected) send({ cmd: "watch", open: root.opened })
  }

  function connectHelper() {
    if (helper.running || root.connecting) return
    root.helperError = ""
    root.notice = ""
    root.connecting = true
    root.quitting = false
    root.helperWanted = true
  }

  function disconnectHelper() {
    if (!helper.running) {
      root.helperWanted = false
      root.connected = false
      root.connecting = false
      return
    }
    root.quitting = true
    send({ cmd: "exit" })
    forceStop.restart()
  }

  function onHelperLine(line) {
    if (line.length > 200000) return
    var message
    try {
      message = JSON.parse(String(line))
    } catch (e) {
      return
    }
    if (!message || !message.type) return

    if (message.type === "hello") {
      root.connected = true
      root.connecting = false
      root.helperError = ""
      root.sendWatch()
      return
    }

    if (message.type === "state") {
      root.snapshot = message
      root.containers = message.containers || []
      root.connected = true
      root.connecting = false
      if (root.selectedName !== "" && !root.containerByName(root.selectedName)) root.selectedName = ""
      if (root.cursor >= root.containers.length) root.cursor = root.containers.length ? root.containers.length - 1 : -1
      return
    }

    if (message.type === "result") {
      root.handleResult(message)
      return
    }

    if (message.type === "fatal") {
      root.helperError = String(message.message || "The helper failed.")
      root.connecting = false
      root.helperWanted = false
    }
  }

  function handleResult(message) {
    var req = String(message.req || "")
    var entry = root.pending[req]
    var action = String(message.action || (entry ? entry.action : ""))
    var name = String(message.name || (entry ? entry.name : ""))
    if (req !== "") {
      var next = {}
      for (var key in root.pending)
        if (key !== req) next[key] = root.pending[key]
      root.pending = next
    }

    if (action === "logs") {
      // Not used by the panel; keep the protocol result harmless.
      return
    }

    if (action === "check") {
      var text = String(message.message || "").split("\n").slice(0, 6).join("\n")
      root.setNotice(text || (message.ok ? "System check passed" : "System check failed"), !message.ok)
      return
    }

    if (!message.ok) {
      root.setNotice(action + (name ? " " + name : "") + " failed: " + String(message.message || "unknown error"), true)
      return
    }
    root.setNotice(action + (name ? " " + name : "") + " ok", false)
  }

  function setNotice(text, isError) {
    root.notice = String(text || "")
    root.noticeIsError = !!isError
    if (root.notice !== "") noticeTimer.restart()
  }

  function requestAction(action, name) {
    if (!root.connected) return
    var req = "r" + (++root.reqSeq)
    var next = {}
    for (var key in root.pending) next[key] = root.pending[key]
    next[req] = { action: action, name: String(name || "") }
    root.pending = next
    root.notice = ""
    send({ cmd: action, name: String(name || ""), req: req })
  }

  function requestCheck() {
    if (!root.connected) return
    var req = "r" + (++root.reqSeq)
    var next = {}
    for (var key in root.pending) next[key] = root.pending[key]
    next[req] = { action: "check", name: "" }
    root.pending = next
    root.notice = ""
    send({ cmd: "check", req: req })
  }

  function busy(name) {
    for (var key in root.pending) {
      var item = root.pending[key]
      if (item && String(item.name || "") === String(name)) return true
    }
    return false
  }

  readonly property bool anyBusy: {
    for (var key in root.pending) return true
    return false
  }

  function refresh() {
    if (root.connected) send({ cmd: "refresh" })
    else root.connectHelper()
  }

  // ---- shell / logs -------------------------------------------------
  function openShell(name) {
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "--title", "Droidspaces · " + String(name),
      "--",
      "pkexec", "/usr/bin/droidspaces", "--name=" + String(name), "enter"
    ])
    root.close()
  }

  function openLog(name) {
    var c = root.containerByName(name)
    if (!c || String(c.log_path || "") === "") return
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "--title", "Droidspaces · " + String(name) + " log",
      "--",
      "tail", "-n", "200", "-f", String(c.log_path)
    ])
    root.close()
  }

  // ---- keyboard -----------------------------------------------------
  function moveCursor(dx, dy) {
    if (containers.length === 0) return
    if (dy !== 0) {
      if (cursor < 0) cursor = dy > 0 ? 0 : containers.length - 1
      else cursor = Math.max(0, Math.min(containers.length - 1, cursor + dy))
      return
    }
    if (dx > 0) {
      if (cursor >= 0) selectedName = String(containers[cursor].name || "")
    } else if (dx < 0) {
      selectedName = ""
    }
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= containers.length) return
    var name = String(containers[cursor].name || "")
    selectedName = selectedName === name ? "" : name
  }

  function toggleSelectedAction() {
    if (cursor < 0 || cursor >= containers.length) return
    var c = containers[cursor]
    requestAction(c.running ? "stop" : "start", String(c.name || ""))
  }

  function closeOrCollapse() {
    if (selectedName !== "") selectedName = ""
    else close()
  }

  onCursorChanged: if (cursor >= 0 && list.visible) list.positionViewAtIndex(cursor, ListView.Contain)

  onOpenedChanged: {
    if (opened) {
      if (!connected && !connecting) connectHelper()
      sendWatch()
    } else {
      sendWatch()
      selectedName = ""
      cursor = -1
    }
  }

  Component.onCompleted: if (connectOnStartup) connectHelper()

  // ---- bar ----------------------------------------------------------
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: root.opened
    activeColor: root.accentColor
    foreground: root.barForeground
    tooltipText: root.barTooltip
    onPressed: function(mouse) {
      if (mouse === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ---- bridge process ----------------------------------------------
  Process {
    id: helper
    running: root.helperWanted
    command: [String(Qt.resolvedUrl("bin/ensure-helper")).replace(/^file:\/\//, "")]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root.onHelperLine(String(line)) }
    }

    onRunningChanged: {
      if (running) return
      root.connected = false
      root.connecting = false
    }

    onExited: function(exitCode, exitStatus) {
      root.helperWanted = false
      root.connected = false
      root.connecting = false
      root.containers = []
      root.snapshot = null
      root.pending = ({})
      forceStop.stop()
      if (root.quitting) {
        root.quitting = false
        return
      }
      if (exitCode === 126)
        root.helperError = "Authentication was dismissed."
      else if (exitCode === 127)
        root.helperError = "Not authorized, or the helper could not be installed."
      else if (exitCode === 77)
        root.helperError = "The helper needs root privileges."
      else
        root.helperError = "The helper stopped (code " + exitCode + ")."
    }
  }

  Timer {
    id: forceStop
    interval: 900
    onTriggered: root.helperWanted = false
  }

  Timer {
    id: noticeTimer
    interval: 7000
    onTriggered: root.notice = ""
  }

  // ---- panel --------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.closeOrCollapse()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "s") root.toggleSelectedAction()
        else if (text === "d") root.disconnectHelper()
        else if (text === "c") root.requestCheck()
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(11)

        // ---------- header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(titleRow.implicitHeight, headerActions.implicitHeight)

          Row {
            id: titleRow
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.barIcon
              color: root.accentColor
              font.family: root.ff
              font.pixelSize: Style.font.iconLarge
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                textFormat: Text.PlainText
                text: "Droidspaces"
                color: root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                visible: root.snapshot !== null
                text: (root.snapshot && String(root.snapshot.version || "") !== ""
                  ? "v" + String(root.snapshot.version).replace(/^v/, "")
                  : "")
                  + (root.snapshot && String(root.snapshot.mode || "") !== ""
                    ? (String(root.snapshot.version || "") !== "" ? "  ·  " : "") + String(root.snapshot.mode)
                    : "")
                color: root.dim
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            PanelActionButton {
              iconText: "\u{f0453}"
              tooltipText: "Refresh"
              foreground: root.barForeground
              hoverColor: root.accentColor
              enabled: root.connected && !root.anyBusy
              onClicked: root.refresh()
            }

            PanelActionButton {
              visible: root.connected || root.connecting
              iconText: "\u{f0156}"
              tooltipText: root.connecting ? "Cancel" : "Disconnect"
              foreground: root.barForeground
              hoverColor: root.urgentColor
              onClicked: root.disconnectHelper()
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---------- not connected ----------
        Column {
          width: parent.width
          spacing: Style.space(9)
          visible: !root.connected

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.helperError !== ""
            text: root.helperError
            color: root.urgentColor
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.connecting
            text: "Waiting for authentication…"
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: !root.connecting
            text: "Droidspaces needs root to read live status and to start, stop or restart containers.\n\n"
                  + "Connecting asks for authentication once per session. After that the bar count and "
                  + "every action work without another prompt, until you log out."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Button {
            visible: !root.connecting
            width: parent.width
            iconText: "\u{f0498}"
            iconSize: Style.font.icon
            text: root.helperError !== "" ? "Try again" : "Connect"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            onClicked: root.connectHelper()
          }

          Button {
            visible: root.connecting
            width: parent.width
            iconText: "\u{f0156}"
            iconSize: Style.font.icon
            text: "Cancel"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            onClicked: root.disconnectHelper()
          }
        }

        // ---------- connected ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.connected

          // summary
          BorderSurface {
            width: parent.width
            implicitHeight: summary.implicitHeight + Style.space(16)
            color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.045)
            radius: Style.cornerRadius

            Row {
              id: summary
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(12)

              Column {
                width: (summary.width - summary.spacing * 2) / 3
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  text: root.runningCount + " / " + root.totalCount
                  color: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: "running"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                width: (summary.width - summary.spacing * 2) / 3
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  text: root.fmtKB(root.ramUsedKb)
                  color: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: "RAM in containers"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                width: (summary.width - summary.spacing * 2) / 3
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  text: String(root.host.load1 !== undefined ? root.host.load1 : "—")
                  color: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: "host load · " + (Number(root.host.cpus) || 0) + " CPUs"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }
          }

          // notice / error
          Text {
            width: parent.width
            visible: root.notice !== ""
            textFormat: Text.PlainText
            text: root.notice
            color: root.noticeIsError ? root.urgentColor : root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            maximumLineCount: 6
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: root.stateError !== ""
            textFormat: Text.PlainText
            text: root.stateError
            color: root.urgentColor
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: !root.available
            textFormat: Text.PlainText
            text: "droidspaces was not found at /usr/bin/droidspaces."
            color: root.urgentColor
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          // empty
          Column {
            width: parent.width
            spacing: Style.space(5)
            visible: root.containers.length === 0
            topPadding: Style.space(10)
            bottomPadding: Style.space(10)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.barIcon
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.display
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: "No containers yet"
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: "Create one with droidspaces in a terminal; it will appear here."
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          // container list
          ListView {
            id: list
            width: parent.width
            height: Math.min(contentHeight, Style.space(330))
            visible: root.containers.length > 0
            clip: true
            spacing: Style.space(3)
            model: root.containers.length
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            delegate: ContainerRow {
              required property int index
              readonly property var item: root.containers[index] || ({})

              width: list.width
              container: item
              expanded: root.selectedName !== "" && String(item.name || "") === root.selectedName
              hasCursor: root.cursor === index
              busy: root.busy(String(item.name || ""))
              foreground: root.barForeground
              dimForeground: root.dim
              accentColor: root.accentColor
              urgentColor: root.urgentColor
              fontFamily: root.ff

              onToggle: {
                root.cursor = index
                var name = String(item.name || "")
                root.selectedName = root.selectedName === name ? "" : name
              }
              onRequestAction: function(action, name) {
                root.cursor = index
                root.requestAction(action, name)
              }
              onOpenShell: function(name) { root.openShell(name) }
              onOpenLog: function(name) { root.openLog(name) }
            }
          }

          // footer
          Row {
            width: parent.width
            spacing: Style.space(7)

            Button {
              width: (parent.width - parent.spacing * 2) / 3
              iconText: "\u{f0453}"
              iconSize: Style.font.icon
              text: "Refresh"
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.ff
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
              bordered: true
              enabled: !root.anyBusy
              onClicked: root.refresh()
            }

            Button {
              width: (parent.width - parent.spacing * 2) / 3
              iconText: "\u{f0188}"
              iconSize: Style.font.icon
              text: "Check"
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.ff
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
              bordered: true
              enabled: !root.anyBusy && root.available
              onClicked: root.requestCheck()
            }

            Button {
              width: (parent.width - parent.spacing * 2) / 3
              iconText: "\u{f0156}"
              iconSize: Style.font.icon
              text: "Disconnect"
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.ff
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
              bordered: true
              onClicked: root.disconnectHelper()
            }
          }
        }
      }
    }
  }
}
