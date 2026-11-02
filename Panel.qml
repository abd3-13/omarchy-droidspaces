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

  // ---- create state -------------------------------------------------
  property bool createOpen: false
  property bool creating: false
  property bool editing: false
  property string editName: ""
  property string deleteTarget: ""
  property bool deleting: false
  property string deleteError: ""
  property string createName: ""
  property string createTarball: ""
  property string createSize: "16G"
  property string createImage: ""
  property bool createStart: false
  property string createStage: ""
  property string createError: ""
  property string createHostname: ""
  property string createInit: ""
  property string createEnvFile: ""
  property string createBind: ""
  property string createNet: "nat"
  property string createNatIp: ""
  property string createUpstream: ""
  property string createPorts: ""
  property string createDns: ""
  property bool createDisableIpv6: false
  property string createGateway: ""
  property string createGatewayNet: ""
  property string createGatewayIface: ""
  property string createGatewayBridge: ""
  property string createMacvlanParent: ""
  property string createMacvlanMode: "bridge"
  property bool createHwAccess: false
  property bool createAllowVts: false
  property bool createGpu: false
  property bool createX11: false
  property string createMemory: ""
  property bool createAllowSwap: false
  property string createCpus: ""
  property string createPids: ""
  property string createPrivileged: ""
  property bool createSelinuxPermissive: false
  property bool createAllowSandboxing: false
  property bool createVolatile: false
  property bool createForceCgroupv1: false

  readonly property string defaultImagePath: {
    var ws = snapshot && snapshot.workspace ? String(snapshot.workspace) : "/var/lib/Droidspaces"
    var name = createName.trim()
    return name === "" ? "" : ws + "/Containers/" + name + "/rootfs.img"
  }

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
      if (!root.deleting && root.deleteTarget !== ""
          && !root.containerByName(root.deleteTarget)) {
        root.deleteTarget = ""
        root.deleteError = ""
      }
      if (root.editing && root.editName !== ""
          && !root.containerByName(root.editName)) {
        root.createOpen = false
        root.editing = false
        root.editName = ""
      }
      return
    }

    if (message.type === "progress") {
      if (String(message.action || "") === "create")
        root.createStage = String(message.stage || message.message || "")
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

    if (action === "create") {
      root.creating = false
      root.createStage = ""
      if (message.ok) {
        root.createOpen = false
        root.createError = ""
        root.setNotice(String(message.message || ("Created " + name)),
                       String(message.start_error || "") !== "")
        root.refresh()
      } else {
        root.createError = String(message.message || "Creation failed.")
      }
      return
    }

    if (action === "config") {
      if (message.ok) {
        root.openEditForm(name, message.form || {})
      } else {
        root.setNotice("Could not load " + name + ": "
                       + String(message.message || "unknown error"), true)
      }
      return
    }

    if (action === "edit") {
      root.creating = false
      root.createStage = ""
      if (message.ok) {
        root.createOpen = false
        root.editing = false
        root.editName = ""
        root.createError = ""
        root.setNotice(String(message.message || ("Saved " + name)), false)
        root.refresh()
      } else {
        root.createError = String(message.message || "Saving failed.")
      }
      return
    }

    if (action === "delete") {
      root.deleting = false
      if (message.ok) {
        root.deleteTarget = ""
        root.deleteError = ""
        root.setNotice(String(message.message || ("Deleted " + name)), false)
        root.refresh()
      } else {
        root.deleteError = String(message.message || "Deletion failed.")
        root.setNotice("Delete " + name + " failed: " + root.deleteError, true)
      }
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

  // ---- create -------------------------------------------------------
  function expandHome(path) {
    var value = String(path || "").trim()
    var home = Quickshell.env("HOME") || ""
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.slice(1)
    return value
  }

  function validContainerName(name) {
    return /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(String(name || ""))
  }

  function toggleText(label, on) {
    return label + (on ? "  ·  on" : "  ·  off")
  }

  function setCreateToggle(key, value) {
    if (key === "hw_access") root.createHwAccess = value
    else if (key === "allow_vts") root.createAllowVts = value
    else if (key === "gpu") root.createGpu = value
    else if (key === "x11") root.createX11 = value
    else if (key === "disable_ipv6") root.createDisableIpv6 = value
    else if (key === "allow_swap") root.createAllowSwap = value
    else if (key === "selinux_permissive") root.createSelinuxPermissive = value
    else if (key === "allow_sandboxing") root.createAllowSandboxing = value
    else if (key === "volatile") root.createVolatile = value
    else if (key === "force_cgroupv1") root.createForceCgroupv1 = value
  }

  function truthy(value) {
    if (typeof value === "boolean") return value
    var text = String(value === undefined || value === null ? "" : value).toLowerCase()
    return text !== "" && text !== "0" && text !== "false"
  }

  function resetFormValues() {
    root.creating = false
    root.createName = ""
    root.createTarball = ""
    root.createSize = "16G"
    root.createImage = ""
    root.createHostname = ""
    root.createInit = ""
    root.createEnvFile = ""
    root.createBind = ""
    root.createNet = "nat"
    root.createNatIp = ""
    root.createUpstream = ""
    root.createPorts = ""
    root.createDns = ""
    root.createDisableIpv6 = false
    root.createGateway = ""
    root.createGatewayNet = ""
    root.createGatewayIface = ""
    root.createGatewayBridge = ""
    root.createMacvlanParent = ""
    root.createMacvlanMode = "bridge"
    root.createHwAccess = false
    root.createAllowVts = false
    root.createGpu = false
    root.createX11 = false
    root.createMemory = ""
    root.createAllowSwap = false
    root.createCpus = ""
    root.createPids = ""
    root.createPrivileged = ""
    root.createSelinuxPermissive = false
    root.createAllowSandboxing = false
    root.createVolatile = false
    root.createForceCgroupv1 = false
    root.createStart = false
    root.createStage = ""
    root.createError = ""
    root.notice = ""
  }

  function syncFormFields() {
    createNameField.text = root.createName
    createTarballField.text = root.createTarball
    createSizeField.text = root.createSize
    createImageField.text = root.createImage
    createHostnameField.text = root.createHostname
    createInitField.text = root.createInit
    createEnvField.text = root.createEnvFile
    createBindField.text = root.createBind
    createNatIpField.text = root.createNatIp
    createUpstreamField.text = root.createUpstream
    createPortsField.text = root.createPorts
    createDnsField.text = root.createDns
    createGatewayField.text = root.createGateway
    createGatewayNetField.text = root.createGatewayNet
    createGatewayIfaceField.text = root.createGatewayIface
    createGatewayBridgeField.text = root.createGatewayBridge
    createMacvlanParentField.text = root.createMacvlanParent
    createMemoryField.text = root.createMemory
    createCpusField.text = root.createCpus
    createPidsField.text = root.createPids
    createPrivilegedField.text = root.createPrivileged
    createNetDropdown.value = root.createNet
    createMacvlanModeDropdown.value = root.createMacvlanMode
  }

  function openCreate() {
    if (!root.connected) return
    root.resetFormValues()
    root.editing = false
    root.editName = ""
    root.deleteTarget = ""
    root.deleteError = ""
    root.syncFormFields()
    root.createOpen = true
    Qt.callLater(function() { createNameField.forceActiveFocus() })
  }

  function openEditForm(name, form) {
    root.resetFormValues()
    root.editing = true
    root.editName = String(name || "")
    root.createName = root.editName
    root.createImage = String(form.rootfs_path || "")
    root.createHostname = String(form.hostname || "")
    root.createInit = String(form.init || "")
    root.createEnvFile = String(form.env_file || "")
    root.createBind = String(form.bind_mounts || "")
    root.createNet = String(form.net_mode || "nat")
    root.createNatIp = String(form.nat_ip || "")
    root.createUpstream = String(form.upstream || "")
    root.createPorts = String(form.ports || "")
    root.createDns = String(form.dns || "")
    root.createDisableIpv6 = !!form.disable_ipv6
    root.createGateway = String(form.gateway || "")
    root.createGatewayNet = String(form.gateway_net || "")
    root.createGatewayIface = String(form.gateway_iface || "")
    root.createGatewayBridge = String(form.gateway_bridge || "")
    root.createMacvlanParent = String(form.macvlan_parent || "")
    root.createMacvlanMode = String(form.macvlan_mode || "bridge")
    root.createHwAccess = !!form.hw_access
    root.createAllowVts = !!form.allow_vts
    root.createGpu = !!form.gpu
    root.createX11 = !!form.x11
    root.createMemory = String(form.memory || "")
    root.createAllowSwap = !!form.allow_swap
    root.createCpus = String(form.cpus || "")
    root.createPids = String(form.pids_limit || "")
    root.createPrivileged = String(form.privileged || "")
    root.createSelinuxPermissive = !!form.selinux_permissive
    root.createAllowSandboxing = !!form.allow_sandboxing
    root.createVolatile = !!form.volatile
    root.createForceCgroupv1 = !!form.force_cgroupv1
    root.deleteTarget = ""
    root.deleteError = ""
    root.syncFormFields()
    root.createOpen = true
    Qt.callLater(function() { createHostnameField.forceActiveFocus() })
  }

  function closeCreate() {
    if (root.creating) return
    root.createOpen = false
    root.createStage = ""
    root.createError = ""
    root.editing = false
    root.editName = ""
  }

  function submitCreate() {
    if (!root.connected || root.creating) return
    var name = root.editing ? root.editName : root.createName.trim()
    var tarball = root.editing ? "" : root.expandHome(root.createTarball)
    var image = root.editing ? root.createImage : root.expandHome(root.createImage)
    var size = root.createSize.trim()
    var hostname = root.createHostname.trim()
    if (!validContainerName(name)) {
      root.createError = "Use 1-64 letters, digits, dots, dashes or underscores; start with a letter or digit."
      return
    }
    if (!root.editing) {
      if (tarball === "") {
        root.createError = "Choose the rootfs tarball you downloaded."
        return
      }
      if (tarball.charAt(0) !== "/") {
        root.createError = "The tarball path must be absolute."
        return
      }
      if (image !== "" && image.charAt(0) !== "/") {
        root.createError = "The image path must be absolute."
        return
      }
      if (size === "") {
        root.createError = "Enter an image size, for example 16G."
        return
      }
    }
    if (hostname !== "" && !/^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/.test(hostname)) {
      root.createError = "Hostname must start with a letter or digit and use letters, digits, dots or dashes."
      return
    }

    var envFile = root.expandHome(root.createEnvFile)
    if (envFile !== "" && envFile.charAt(0) !== "/") {
      root.createError = "The environment file path must be absolute."
      return
    }

    var action = root.editing ? "edit" : "create"
    var req = "r" + (++root.reqSeq)
    var next = {}
    for (var key in root.pending) next[key] = root.pending[key]
    next[req] = { action: action, name: name }
    root.pending = next
    root.creating = true
    root.createError = ""
    root.createStage = root.editing ? "Saving…" : "Queued…"

    var message = {
      cmd: action,
      req: req,
      name: name,
      hostname: hostname,
      options: {
        init: root.createInit.trim(),
        env_file: envFile,
        bind_mounts: root.createBind.trim(),
        net_mode: root.createNet,
        nat_ip: root.createNatIp.trim(),
        upstream: root.createUpstream.trim(),
        ports: root.createPorts.trim(),
        dns: root.createDns.trim(),
        disable_ipv6: root.createDisableIpv6,
        gateway: root.createGateway.trim(),
        gateway_net: root.createGatewayNet.trim(),
        gateway_iface: root.createGatewayIface.trim(),
        gateway_bridge: root.createGatewayBridge.trim(),
        macvlan_parent: root.createMacvlanParent.trim(),
        macvlan_mode: root.createMacvlanMode,
        hw_access: root.createHwAccess,
        allow_vts: root.createAllowVts,
        gpu: root.createGpu,
        x11: root.createX11,
        memory: root.createMemory.trim(),
        allow_swap: root.createAllowSwap,
        cpus: root.createCpus.trim(),
        pids_limit: root.createPids.trim(),
        privileged: root.createPrivileged.trim(),
        selinux_permissive: root.createSelinuxPermissive,
        allow_sandboxing: root.createAllowSandboxing,
        volatile: root.createVolatile,
        force_cgroupv1: root.createForceCgroupv1
      }
    }
    if (!root.editing) {
      message.tarball = tarball
      message.size = size
      message.start = root.createStart
      if (image !== "") message.image = image
    }

    if (!send(message)) {
      var rest = {}
      for (var other in root.pending)
        if (other !== req) rest[other] = root.pending[other]
      root.pending = rest
      root.creating = false
      root.createStage = ""
      root.createError = "The helper is not connected."
    }
  }

  function browseTarball() {
    if (!root.creating) filePicker.running = true
  }

  // ---- edit / delete ------------------------------------------------
  function requestEdit(name) {
    if (!root.connected || root.anyBusy) return
    var req = "r" + (++root.reqSeq)
    var next = {}
    for (var key in root.pending) next[key] = root.pending[key]
    next[req] = { action: "config", name: String(name || "") }
    root.pending = next
    root.notice = ""
    root.deleteTarget = ""
    root.deleteError = ""
    if (!send({ cmd: "config", name: String(name || ""), req: req })) {
      var rest = {}
      for (var other in root.pending)
        if (other !== req) rest[other] = root.pending[other]
      root.pending = rest
      root.setNotice("The helper is not connected.", true)
    }
  }

  function requestDelete(name) {
    if (!root.connected || root.anyBusy) return
    var c = root.containerByName(name)
    if (c && c.running) {
      root.setNotice("Stop " + String(name) + " before deleting it.", true)
      return
    }
    root.deleteTarget = String(name || "")
    root.deleteError = ""
    root.createOpen = false
    root.editing = false
    root.editName = ""
    root.notice = ""
  }

  function confirmDelete() {
    if (!root.connected || root.deleteTarget === "" || root.deleting) return
    var name = root.deleteTarget
    var req = "r" + (++root.reqSeq)
    var next = {}
    for (var key in root.pending) next[key] = root.pending[key]
    next[req] = { action: "delete", name: name }
    root.pending = next
    root.deleting = true
    root.deleteError = ""
    if (!send({ cmd: "delete", name: name, req: req })) {
      var rest = {}
      for (var other in root.pending)
        if (other !== req) rest[other] = root.pending[other]
      root.pending = rest
      root.deleting = false
      root.deleteError = "The helper is not connected."
    }
  }

  function cancelDelete() {
    if (root.deleting) return
    root.deleteTarget = ""
    root.deleteError = ""
  }

  function editSelected() {
    if (cursor < 0 || cursor >= containers.length) return
    requestEdit(String(containers[cursor].name || ""))
  }

  function deleteSelected() {
    if (cursor < 0 || cursor >= containers.length) return
    requestDelete(String(containers[cursor].name || ""))
  }

  // ---- shell / logs -------------------------------------------------
  function openShell(name) {
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "--title=Droidspaces · " + String(name),
      "-e",
      "pkexec", "/usr/bin/droidspaces", "--name=" + String(name), "enter"
    ])
    root.close()
  }

  function openLog(name) {
    var c = root.containerByName(name)
    if (!c || String(c.log_path || "") === "") return
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "--title=Droidspaces · " + String(name) + " log",
      "-e",
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
      if (!root.creating && !filePicker.running) root.createOpen = false
      if (!root.deleting) {
        root.deleteTarget = ""
        root.deleteError = ""
      }
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
      root.creating = false
      root.createStage = ""
      root.createOpen = false
      root.editing = false
      root.editName = ""
      root.deleting = false
      root.deleteTarget = ""
      root.deleteError = ""
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

  Process {
    id: filePicker
    running: false
    command: [
      "omarchy-file-select",
      "--title", "Select a rootfs tarball",
      "--extensions", "tar xz gz bz2 zst txz tgz"
    ]

    stdout: SplitParser {
      onRead: function(line) {
        var picked = String(line).trim()
        if (picked === "") return
        root.createTarball = picked
        createTarballField.text = picked
      }
    }

    onExited: function(exitCode, exitStatus) {
      if (exitCode === 2)
        root.createError = "The file chooser failed; type the path instead."
      else if (exitCode === 127)
        root.createError = "The file chooser could not be started; type the path instead."
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
      blocked: root.createOpen

      onCloseRequested: root.closeOrCollapse()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "s") root.toggleSelectedAction()
        else if (text === "d") root.disconnectHelper()
        else if (text === "c") root.requestCheck()
        else if (text === "n") root.openCreate()
        else if (text === "e") root.editSelected()
        else if (text === "x") root.deleteSelected()
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
              enabled: !root.creating
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

        // ---------- create ----------
        Flickable {
          id: createForm
          width: parent.width
          height: Math.min(createFormColumn.implicitHeight, Style.space(470))
          contentWidth: width
          contentHeight: createFormColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          visible: root.connected && root.createOpen
          focus: root.createOpen

          Keys.onEscapePressed: function(event) {
            root.closeCreate()
            event.accepted = true
          }

          Column {
            id: createFormColumn
            width: createForm.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: root.editing ? "Edit " + root.editName : "New container"
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.editing
                ? "Updates the container configuration. The name and rootfs stay the same; "
                  + "changes apply the next time the container starts."
                : "Creates a sparse ext4 image and extracts a rootfs tarball into it. "
                  + "The container is added to the list, stopped unless you ask to start it."
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              visible: root.editing
              textFormat: Text.PlainText
              text: "Rootfs: " + root.createImage
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Text {
              visible: !root.editing
              textFormat: Text.PlainText
              text: "Name"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: createNameField
              visible: !root.editing
              width: parent.width
              placeholderText: "ubuntu"
              foreground: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.body
              enabled: !root.creating
              text: root.createName
              onTextChanged: if (text !== root.createName) root.createName = text
              Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
            }

            Text {
              visible: !root.editing
              textFormat: Text.PlainText
              text: "Rootfs tarball"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }

            Row {
              visible: !root.editing
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: createTarballField
                width: parent.width - browseButton.width - parent.spacing
                placeholderText: "/home/you/Downloads/rootfs.tar.xz"
                foreground: root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.body
                enabled: !root.creating
                text: root.createTarball
                onTextChanged: if (text !== root.createTarball) root.createTarball = text
                Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
              }

              Button {
                id: browseButton
                width: Style.space(92)
                iconText: "\u{f0256}"
                iconSize: Style.font.icon
                text: "Browse"
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.ff
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
                bordered: true
                enabled: !root.creating
                onClicked: root.browseTarball()
              }
            }

            Row {
              visible: !root.editing
              width: parent.width
              spacing: Style.space(8)

              Column {
                width: (parent.width - parent.spacing) * 0.36
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Image size"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createSizeField
                  width: parent.width
                  placeholderText: "16G"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createSize
                  onTextChanged: if (text !== root.createSize) root.createSize = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Column {
                width: parent.width - (parent.width - parent.spacing) * 0.36 - parent.spacing
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Image path (optional)"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createImageField
                  width: parent.width
                  placeholderText: root.defaultImagePath !== "" ? root.defaultImagePath
                    : "Default: <workspace>/Containers/<name>/rootfs.img"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createImage
                  onTextChanged: if (text !== root.createImage) root.createImage = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Container options"
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              topPadding: Style.space(2)
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Hostname"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createHostnameField
                  width: parent.width
                  placeholderText: "Defaults to container name"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createHostname
                  onTextChanged: if (text !== root.createHostname) root.createHostname = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Init binary"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createInitField
                  width: parent.width
                  placeholderText: "/sbin/init"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createInit
                  onTextChanged: if (text !== root.createInit) root.createInit = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Environment file (optional)"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: createEnvField
              width: parent.width
              placeholderText: "/path/to/container.env"
              foreground: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.body
              enabled: !root.creating
              text: root.createEnvFile
              onTextChanged: if (text !== root.createEnvFile) root.createEnvFile = text
              Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
            }

            Text {
              textFormat: Text.PlainText
              text: "Bind mounts (optional)"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: createBindField
              width: parent.width
              placeholderText: "/srv/a:/mnt/a:ro,/srv/b:/mnt/b"
              foreground: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.body
              enabled: !root.creating
              text: root.createBind
              onTextChanged: if (text !== root.createBind) root.createBind = text
              Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Network"
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              topPadding: Style.space(2)
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Dropdown {
                id: createNetDropdown
                width: (parent.width - parent.spacing) / 2
                label: "Mode"
                options: ["nat", "host", "none", "gateway", "macvlan"]
                value: root.createNet
                foreground: root.barForeground
                fontFamily: root.ff
                onChanged: if (value !== root.createNet) root.createNet = value
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "DNS servers"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createDnsField
                  width: parent.width
                  placeholderText: "1.1.1.1,9.9.9.9"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createDns
                  onTextChanged: if (text !== root.createDns) root.createDns = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              visible: root.createNet === "nat"

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Static NAT IP"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createNatIpField
                  width: parent.width
                  placeholderText: "172.28.0.20"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createNatIp
                  onTextChanged: if (text !== root.createNatIp) root.createNatIp = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Upstream interfaces"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createUpstreamField
                  width: parent.width
                  placeholderText: "eth0,wlan*"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createUpstream
                  onTextChanged: if (text !== root.createUpstream) root.createUpstream = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.createNet === "nat"
              textFormat: Text.PlainText
              text: "Port forwards (optional)"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: createPortsField
              width: parent.width
              visible: root.createNet === "nat"
              placeholderText: "8080:80,5353:53/udp"
              foreground: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.body
              enabled: !root.creating
              text: root.createPorts
              onTextChanged: if (text !== root.createPorts) root.createPorts = text
              Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              visible: root.createNet === "gateway"

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Gateway container"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createGatewayField
                  width: parent.width
                  placeholderText: "openwrt"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createGateway
                  onTextChanged: if (text !== root.createGateway) root.createGateway = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Gateway network"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createGatewayNetField
                  width: parent.width
                  placeholderText: "lan"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createGatewayNet
                  onTextChanged: if (text !== root.createGatewayNet) root.createGatewayNet = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              visible: root.createNet === "gateway"

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Gateway interface"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createGatewayIfaceField
                  width: parent.width
                  placeholderText: "eth1"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createGatewayIface
                  onTextChanged: if (text !== root.createGatewayIface) root.createGatewayIface = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Gateway bridge"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createGatewayBridgeField
                  width: parent.width
                  placeholderText: "ds-lan"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createGatewayBridge
                  onTextChanged: if (text !== root.createGatewayBridge) root.createGatewayBridge = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              visible: root.createNet === "macvlan"

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Parent interface"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createMacvlanParentField
                  width: parent.width
                  placeholderText: "eth0"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createMacvlanParent
                  onTextChanged: if (text !== root.createMacvlanParent) root.createMacvlanParent = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Dropdown {
                id: createMacvlanModeDropdown
                width: (parent.width - parent.spacing) / 2
                label: "MACVLAN mode"
                options: ["bridge", "private", "vepa", "passthru"]
                value: root.createMacvlanMode
                foreground: root.barForeground
                fontFamily: root.ff
                onChanged: if (value !== root.createMacvlanMode) root.createMacvlanMode = value
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Resources and security"
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              topPadding: Style.space(2)
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Column {
                width: (parent.width - 2 * parent.spacing) / 3
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Memory"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createMemoryField
                  width: parent.width
                  placeholderText: "2G"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createMemory
                  onTextChanged: if (text !== root.createMemory) root.createMemory = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Column {
                width: (parent.width - 2 * parent.spacing) / 3
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "CPUs"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createCpusField
                  width: parent.width
                  placeholderText: "1.5"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createCpus
                  onTextChanged: if (text !== root.createCpus) root.createCpus = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }

              Column {
                width: (parent.width - 2 * parent.spacing) / 3
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "PID limit"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: createPidsField
                  width: parent.width
                  placeholderText: "512"
                  foreground: root.barForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  enabled: !root.creating
                  text: root.createPids
                  onTextChanged: if (text !== root.createPids) root.createPids = text
                  Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Privileged tags (optional)"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: createPrivilegedField
              width: parent.width
              placeholderText: "nomask,nocaps"
              foreground: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.body
              enabled: !root.creating
              text: root.createPrivileged
              onTextChanged: if (text !== root.createPrivileged) root.createPrivileged = text
              Keys.onEscapePressed: function(event) { root.closeCreate(); event.accepted = true }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Hardware and boot"
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              topPadding: Style.space(2)
            }

            Grid {
              id: optionToggles
              width: parent.width
              columns: 2
              rowSpacing: Style.space(6)
              columnSpacing: Style.space(6)

              Repeater {
                model: [
                  { key: "hw_access", label: "Hardware access", active: root.createHwAccess },
                  { key: "allow_vts", label: "Virtual terminals", active: root.createAllowVts },
                  { key: "gpu", label: "GPU mode", active: root.createGpu },
                  { key: "x11", label: "X11 socket", active: root.createX11 },
                  { key: "disable_ipv6", label: "Disable IPv6", active: root.createDisableIpv6 },
                  { key: "allow_swap", label: "Allow swap", active: root.createAllowSwap },
                  { key: "selinux_permissive", label: "SELinux permissive", active: root.createSelinuxPermissive },
                  { key: "allow_sandboxing", label: "Allow sandboxing", active: root.createAllowSandboxing },
                  { key: "volatile", label: "Volatile mode", active: root.createVolatile },
                  { key: "force_cgroupv1", label: "Force cgroup v1", active: root.createForceCgroupv1 }
                ]

                delegate: Button {
                  required property var modelData
                  width: (optionToggles.width - optionToggles.columnSpacing) / 2
                  iconText: modelData.active ? "\u{f0132}" : "\u{f0133}"
                  iconSize: Style.font.icon
                  text: root.toggleText(modelData.label, modelData.active)
                  fontSize: Style.font.bodySmall
                  foreground: root.barForeground
                  fontFamily: root.ff
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
                  bordered: true
                  selected: modelData.active
                  enabled: !root.creating
                  onClicked: root.setCreateToggle(modelData.key, !modelData.active)
                }
              }
            }

            Button {
              visible: !root.editing
              width: parent.width
              iconText: root.createStart ? "\u{f0132}" : "\u{f0133}"
              iconSize: Style.font.icon
              text: root.createStart ? "Start after creation  ·  on" : "Start after creation  ·  off"
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.ff
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
              bordered: true
              selected: root.createStart
              enabled: !root.creating
              onClicked: root.createStart = !root.createStart
            }

            Text {
              width: parent.width
              visible: root.creating && root.createStage !== ""
              textFormat: Text.PlainText
              text: root.createStage
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              visible: root.createError !== ""
              textFormat: Text.PlainText
              text: root.createError
              color: root.urgentColor
              font.family: root.ff
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              maximumLineCount: 5
              elide: Text.ElideRight
            }

            Row {
              width: parent.width
              spacing: Style.space(7)

              Button {
                width: (parent.width - parent.spacing) / 2
                iconText: "\u{f0156}"
                iconSize: Style.font.icon
                text: "Cancel"
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.ff
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
                bordered: true
                enabled: !root.creating
                onClicked: root.closeCreate()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                iconText: root.creating ? "\u{f0453}" : (root.editing ? "\u{f0193}" : "\u{f0415}")
                iconSize: Style.font.icon
                iconSpinning: root.creating
                text: root.creating
                  ? (root.editing ? "Saving…" : "Creating…")
                  : (root.editing ? "Save" : "Create")
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.ff
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
                bordered: true
                enabled: !root.creating && root.available
                onClicked: root.submitCreate()
              }
            }
          }
        }

        // ---------- connected ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.connected && !root.createOpen

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

          // delete confirmation
          BorderSurface {
            width: parent.width
            visible: root.deleteTarget !== ""
            implicitHeight: deleteConfirm.implicitHeight + Style.space(16)
            color: Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.08)
            radius: Style.cornerRadius

            Column {
              id: deleteConfirm
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(6)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Delete " + root.deleteTarget + "?"
                color: root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                wrapMode: Text.Wrap
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "This removes the container folder and its rootfs image. It cannot be undone."
                color: root.dim
                font.family: root.ff
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              Text {
                width: parent.width
                visible: root.deleteError !== ""
                textFormat: Text.PlainText
                text: root.deleteError
                color: root.urgentColor
                font.family: root.ff
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
              }

              Row {
                width: parent.width
                spacing: Style.space(7)

                Button {
                  width: (parent.width - parent.spacing) / 2
                  iconText: "\u{f0156}"
                  iconSize: Style.font.icon
                  text: "Cancel"
                  fontSize: Style.font.bodySmall
                  foreground: root.barForeground
                  fontFamily: root.ff
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
                  bordered: true
                  enabled: !root.deleting
                  onClicked: root.cancelDelete()
                }

                Button {
                  width: (parent.width - parent.spacing) / 2
                  iconText: root.deleting ? "\u{f0453}" : "\u{f01b4}"
                  iconSize: Style.font.icon
                  iconSpinning: root.deleting
                  text: root.deleting ? "Deleting…" : "Delete"
                  fontSize: Style.font.bodySmall
                  foreground: root.urgentColor
                  fontFamily: root.ff
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(1)
                  bordered: true
                  enabled: !root.deleting
                  onClicked: root.confirmDelete()
                }
              }
            }
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
              text: "Use New container below to install a rootfs tarball into an ext4 image."
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
              onEditContainer: function(name) { root.requestEdit(name) }
              onDeleteContainer: function(name) { root.requestDelete(name) }
            }
          }

          // new container
          Button {
            width: parent.width
            iconText: "\u{f0415}"
            iconSize: Style.font.icon
            text: "New container"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            enabled: root.available && !root.anyBusy
            onClicked: root.openCreate()
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
