import QtQuick
import qs.Commons
import qs.Ui

// One container row: name, live figures, inline actions and an optional
// details block. Kept out of Panel.qml so the list stays a clean ListView.
Item {
  id: row

  property var container: ({})
  property bool expanded: false
  property bool hasCursor: false
  property bool busy: false
  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(foreground, 1.45)
  property color accentColor: Color.accent
  property color urgentColor: Color.urgent
  property string fontFamily: Style.font.family

  signal toggle()
  signal requestAction(string action, string name)
  signal openShell(string name)
  signal openLog(string name)
  signal editContainer(string name)
  signal deleteContainer(string name)

  readonly property string name: String(container.name || "")
  readonly property bool running: !!container.running
  readonly property bool rootfsMissing: container.rootfs_exists === false
  readonly property real cpuPercent: (Number(container.cpu_permill) || 0) / 10
  readonly property real ramUsedKb: Number(container.ram_used_kb) || 0
  readonly property real ramLimitKb: Number(container.ram_limit_kb) || 0
  readonly property string statusText: busy ? "working…" : (running ? "running" : (rootfsMissing ? "rootfs missing" : "stopped"))
  readonly property color statusColor: busy ? accentColor : (running ? accentColor : (rootfsMissing ? urgentColor : dimForeground))

  width: parent ? parent.width : 0
  implicitHeight: card.implicitHeight

  function fmtKB(kb) {
    var v = Number(kb) || 0
    if (v <= 0) return "0"
    if (v < 1024) return Math.round(v) + "K"
    if (v < 1024 * 1024) return (v / 1024 < 10 ? (Math.round(v / 102.4) / 10) : Math.round(v / 1024)) + "M"
    return (v / 1048576 < 10 ? (Math.round(v / 104857.6) / 10) : Math.round(v / 1048576)) + "G"
  }

  function fmtBytes(bytes) {
    return fmtKB((Number(bytes) || 0) / 1024)
  }

  function detail(label, value, error) {
    return {
      label: label,
      value: String(value === undefined || value === null || value === "" ? "—" : value),
      error: !!error
    }
  }

  readonly property var details: [
    detail("Rootfs", container.rootfs_path ? (String(container.rootfs_path) + " (" + String(container.rootfs_kind || "?") + ")") : "—", rootfsMissing),
    detail("Network", String(container.net_mode || "nat") + (container.ip ? "  ·  " + container.ip : (container.ip6 ? "  ·  " + container.ip6 : ""))),
    detail("Ports", container.port_forwards),
    detail("Memory limit", ramLimitKb > 0 ? fmtKB(ramLimitKb) : "unlimited"),
    detail("CPU limit", Number(container.cpu_limit_cores) > 0 ? Number(container.cpu_limit_cores) + " cores" : "unlimited"),
    detail("PID limit", Number(container.pids_limit) > 0 ? String(container.pids_limit) : "unlimited"),
    detail("Bind mounts", container.bind_mounts),
    detail("DNS", container.dns_servers),
    detail("Privileged", container.privileged),
    detail("PID", running && Number(container.pid) > 0 ? String(container.pid) : "—")
  ]

  BorderSurface {
    id: card
    width: parent.width
    implicitHeight: body.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: row.hasCursor
      ? Style.hoverFillFor(row.foreground, row.accentColor)
      : "transparent"
    borderSpec: row.expanded || row.hasCursor
      ? Border.controlSpec("normal", row.foreground, row.accentColor)
      : Border.none()

    Behavior on color { ColorAnimation { duration: 80 } }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      spacing: Style.space(5)

      // ---- name + status + actions ----
      Item {
        width: parent.width
        implicitHeight: Math.max(nameLine.implicitHeight, actions.implicitHeight)

        Row {
          id: nameLine
          anchors.left: parent.left
          anchors.right: actions.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(7)

          Rectangle {
            width: Style.space(6)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: row.statusColor
            opacity: row.running || row.busy ? 1 : 0.45
          }

          Text {
            textFormat: Text.PlainText
            text: row.name
            color: row.foreground
            font.family: row.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: row.statusText
            color: row.statusColor
            font.family: row.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          id: actions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          PanelActionButton {
            iconText: row.running ? "\u{f04db}" : "\u{f040a}"
            tooltipText: row.running ? "Stop" : (row.rootfsMissing ? "Rootfs is missing" : "Start")
            foreground: row.foreground
            hoverColor: row.running ? row.urgentColor : row.accentColor
            enabled: !row.busy && !(row.rootfsMissing && !row.running)
            onClicked: row.requestAction(row.running ? "stop" : "start", row.name)
          }

          PanelActionButton {
            visible: row.running
            iconText: "\u{f0709}"
            tooltipText: "Restart"
            foreground: row.foreground
            hoverColor: row.accentColor
            enabled: !row.busy
            onClicked: row.requestAction("restart", row.name)
          }

          PanelActionButton {
            visible: row.running
            iconText: "\u{f018d}"
            tooltipText: "Open shell (authenticate once)"
            foreground: row.foreground
            hoverColor: row.accentColor
            enabled: !row.busy
            onClicked: row.openShell(row.name)
          }

          PanelActionButton {
            visible: String(row.container.log_path || "") !== ""
            iconText: "\u{f0219}"
            tooltipText: "Open log"
            foreground: row.foreground
            hoverColor: row.accentColor
            onClicked: row.openLog(row.name)
          }

          PanelActionButton {
            iconText: row.expanded ? "\u{f0143}" : "\u{f0140}"
            tooltipText: row.expanded ? "Hide details" : "Details"
            foreground: row.foreground
            hoverColor: row.accentColor
            onClicked: row.toggle()
          }
        }
      }

      // ---- live figures ----
      Item {
        width: parent.width
        implicitHeight: Math.max(metaLeft.implicitHeight, metaRight.implicitHeight)

        Text {
          id: metaLeft
          anchors.left: parent.left
          anchors.right: metaRight.left
          anchors.rightMargin: Style.space(8)
          textFormat: Text.PlainText
          text: row.running
            ? (String(row.container.os || "") !== ""
                ? String(row.container.os) + "  ·  " + String(row.container.hostname || "")
                : String(row.container.hostname || ""))
            : (row.rootfsMissing
                ? "rootfs missing  ·  " + String(row.container.rootfs_path || "")
                : "not running")
          color: row.dimForeground
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          id: metaRight
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: row.running
            ? (String(row.container.ip || "") !== "" ? String(row.container.ip) : "no ip")
              + (String(row.container.uptime || "") !== "" ? "  ·  " + String(row.container.uptime) : "")
            : ""
          color: row.dimForeground
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- resources ----
      Row {
        width: parent.width
        spacing: Style.space(14)
        visible: row.running

        Text {
          textFormat: Text.PlainText
          text: "CPU  " + (Math.round(row.cpuPercent * 10) / 10) + "%"
          color: row.cpuPercent >= 80 ? row.urgentColor : row.foreground
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          text: "RAM  " + row.fmtKB(row.ramUsedKb)
                + (row.ramLimitKb > 0 ? " / " + row.fmtKB(row.ramLimitKb) : "")
          color: row.ramLimitKb > 0 && row.ramUsedKb >= row.ramLimitKb * 0.9
            ? row.urgentColor : row.foreground
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: !!row.container.swap_allowed
          textFormat: Text.PlainText
          text: "swap"
          color: row.dimForeground
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator {
        visible: row.expanded
        foreground: row.foreground
        strength: 0.08
      }

      // ---- details ----
      Column {
        width: parent.width
        spacing: Style.space(3)
        visible: row.expanded

        Repeater {
          model: row.expanded ? row.details.length : 0

          Item {
            required property int index
            readonly property var item: row.details[index] || ({ label: "", value: "" })
            width: body.width
            implicitHeight: Math.max(detailLabel.implicitHeight, detailValue.implicitHeight)

            Text {
              id: detailLabel
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: item.label
              color: row.dimForeground
              font.family: row.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              id: detailValue
              anchors.right: parent.right
              width: Math.min(parent.width * 0.68, implicitWidth)
              textFormat: Text.PlainText
              text: item.value
              color: item.error ? row.urgentColor : row.foreground
              font.family: row.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideMiddle
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Edit"
            fontSize: Style.font.bodySmall
            foreground: row.foreground
            fontFamily: row.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
            bordered: true
            enabled: !row.busy
            onClicked: row.editContainer(row.name)
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Delete"
            fontSize: Style.font.bodySmall
            foreground: row.urgentColor
            fontFamily: row.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
            bordered: true
            enabled: !row.busy
            onClicked: row.deleteContainer(row.name)
          }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    z: -1
    onClicked: row.toggle()
  }
}
