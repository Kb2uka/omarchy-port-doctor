import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "kb2uka.port-doctor"
  ipcTarget: "kb2uka.port-doctor"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- scanning

  readonly property string scannerPath: decodeURIComponent(
    Qt.resolvedUrl("port-doctor.py").toString().replace(/^file:\/\//, ""))
  readonly property int pollMs: {
    var v = Number(setting("scanIntervalSec", 300))
    return (isFinite(v) && v >= 30 && v <= 3600 ? Math.round(v) : 300) * 1000
  }

  property string view: "network"
  property var hosts: []
  property var lanNetwork: ({})
  property var lanStats: ({})
  property string lanScannedAt: ""
  property bool lanFailed: false
  property var newIps: ({})
  property var _knownIps: ({})

  property var listeners: []
  property var connections: []
  property var machineStats: ({})
  property string machineScannedAt: ""
  property bool machineFailed: false
  property string machineHostname: ""

  property int cursorIndex: 0
  property string selectedKey: ""
  property string expandedIp: ""
  property bool keyboardNav: false
  property double lastPointerMoveMs: 0

  readonly property int openPorts: lanStats.openPorts || 0
  readonly property bool scanning: lanProcess.running

  function rescanLan() {
    if (!lanProcess.running) lanProcess.running = true
  }

  function rescanMachine() {
    if (!machineProcess.running) machineProcess.running = true
  }

  Process {
    id: lanProcess
    running: false
    command: ["/usr/bin/python3", "-I", "-B", root.scannerPath, "lan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLan(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("port-doctor", text.trim())
    }
  }

  // A scan wedged on a stuck resolver must not pin the panel in "scanning".
  Timer {
    interval: 15000
    repeat: false
    running: lanProcess.running
    onTriggered: {
      lanFailed = true
      lanProcess.signal(9)
    }
  }

  Process {
    id: machineProcess
    running: false
    command: ["/usr/bin/python3", "-I", "-B", root.scannerPath, "machine"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyMachine(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("port-doctor", text.trim())
    }
  }

  Timer {
    interval: 5000
    repeat: false
    running: machineProcess.running
    onTriggered: {
      machineFailed = true
      machineProcess.signal(9)
    }
  }

  // The LAN scan is the expensive half: slow clock, whether open or not.
  Timer {
    interval: root.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.rescanLan()
  }

  // The machine view is cheap proc reads: live refresh while it is showing.
  Timer {
    interval: 2500
    running: root.opened && root.view === "machine"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.rescanMachine()
  }

  function applyLan(text) {
    var payload
    try {
      payload = JSON.parse(String(text || ""))
    } catch (e) {
      lanFailed = true
      return
    }
    if (!payload || !payload.hosts) { lanFailed = true; return }
    // A failed scan must not wipe the last good view or the NEW-baseline:
    // hosts stay as they were and reappearing hosts are not re-marked NEW.
    if (payload.error) { lanFailed = true; return }
    lanFailed = false
    lanScannedAt = String(payload.scannedAt || "")
    lanNetwork = payload.network || ({})
    lanStats = payload.stats || ({})
    var incoming = payload.hosts
    var found = {}
    var fresh = {}
    var hadBaseline = false
    for (var k in _knownIps) hadBaseline = true
    for (var i = 0; i < incoming.length; i++) {
      var ip = String(incoming[i].ip || "")
      found[ip] = true
      if (hadBaseline && !_knownIps[ip]) fresh[ip] = true
    }
    newIps = fresh
    _knownIps = found
    hosts = incoming
    reconcileSelection()
  }

  function applyMachine(text) {
    var payload
    try {
      payload = JSON.parse(String(text || ""))
    } catch (e) {
      machineFailed = true
      return
    }
    if (!payload || !payload.listeners) { machineFailed = true; return }
    machineFailed = !!payload.error
    machineScannedAt = String(payload.scannedAt || "")
    machineHostname = String(payload.hostname || "")
    machineStats = payload.stats || ({})
    listeners = payload.listeners
    connections = payload.connections || []
    reconcileSelection()
  }

  // Selection follows a stable key, not an index, so a refresh never moves
  // the highlight onto a different row.
  function reconcileSelection() {
    var rows = flatRows
    if (selectedKey !== "") {
      for (var i = 0; i < rows.length; i++)
        if (rows[i].key === selectedKey) { cursorIndex = i; return }
    }
    cursorIndex = clamp(cursorIndex, 0, Math.max(0, rows.length - 1))
    selectedKey = rows.length > 0 ? rows[cursorIndex].key : ""
  }

  function noteCursor(index) {
    cursorIndex = index
    selectedKey = (index >= 0 && index < flatRows.length) ? flatRows[index].key : ""
  }

  // ------------------------------------------------------------- view model

  // One flat cursor list per view: network rows are hosts, machine rows are
  // listeners then connections. Selection follows a stable key, not an index,
  // so a refresh never moves the highlight onto a different row.
  readonly property var flatRows: {
    if (view === "network") {
      var rows = []
      for (var i = 0; i < hosts.length; i++) {
        var h = hosts[i]
        rows.push({ kind: "host", key: "h:" + String(h.ip || i), host: h })
      }
      return rows
    }
    var rows = []
    for (var j = 0; j < listeners.length; j++)
      rows.push({ kind: "listener", key: "l:" + listeners[j].proto + ":" + listeners[j].bind + ":" + listeners[j].port, listener: listeners[j] })
    for (var k = 0; k < connections.length; k++) {
      var c = connections[k]
      rows.push({ kind: "connection", key: "c:" + c.proto + ":" + c.localPort + ":" + c.remoteIp + ":" + c.remotePort, conn: c })
    }
    return rows
  }

  // Class palette as real color values: string hex would render black when
  // read as .r/.g/.b inside the Canvas painter.
  function classColor(klass) {
    switch (String(klass)) {
      case "remote": return Qt.rgba(0.357, 0.553, 0.937)
      case "web": return Qt.rgba(0.247, 0.663, 0.486)
      case "media": return Qt.rgba(0.608, 0.549, 1.0)
      case "file": return Qt.rgba(0.898, 0.753, 0.482)
      case "print": return Qt.rgba(0.604, 0.655, 0.690)
      case "iot": return Qt.rgba(0.949, 0.471, 0.624)
      case "db": return Qt.rgba(0.949, 0.631, 0.329)
      case "mail": return Qt.rgba(0.400, 0.761, 0.820)
      case "infra": return Qt.rgba(0.647, 0.706, 0.988)
      default: return alpha(foreground, 0.75)
    }
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function moveCursor(delta) {
    if (flatRows.length === 0) return
    keyboardNav = true
    cursorIndex = clamp(cursorIndex + delta, 0, flatRows.length - 1)
    if (flatRows[cursorIndex]) selectedKey = flatRows[cursorIndex].key
  }

  function switchView(direction) {
    var next = view === "network" ? "machine" : "network"
    if (direction < 0) next = view === "network" ? "machine" : "network"
    if (next === view) return
    view = next
    cursorIndex = 0
    selectedKey = ""
    keyboardNav = false
    if (view === "machine") rescanMachine()
  }

  function activate(row) {
    if (!row) return
    if (row.kind === "host") {
      var ip = String(row.host.ip || "")
      expandedIp = expandedIp === ip ? "" : ip
    }
  }

  function scrollTo(itemY) {
    if (!panelFlick) return
    var target = clamp(itemY - panelFlick.height / 2, 0,
                       Math.max(0, panelFlick.contentHeight - panelFlick.height))
    panelFlick.contentY = target
  }

  function ageText(iso) {
    if (!iso || iso.length < 19) return ""
    var then = new Date(iso)
    if (isNaN(then.getTime())) return ""
    var s = Math.max(0, Math.round((Date.now() - then.getTime()) / 1000))
    if (s < 5) return "just now"
    if (s < 60) return s + "s ago"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m ago"
    return Math.floor(m / 60) + "h ago"
  }

  onOpenedChanged: if (opened) {
    cursorIndex = 0
    selectedKey = ""
    keyboardNav = false
    rescanMachine()
    if (lanScannedAt === "" ||
        Date.now() - new Date(lanScannedAt).getTime() > 30000)
      rescanLan()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0317}"
    active: root.hosts.length > 0 || root.scanning
    tooltipText: root.scanning
      ? "Port Doctor · scanning " + (root.lanNetwork.cidr || "network") + "…"
      : (root.lanFailed
        ? "Port Doctor · scan failed"
        : "Port Doctor · " + root.hosts.length + " host" + (root.hosts.length === 1 ? "" : "s")
          + " · " + root.openPorts + " open port" + (root.openPorts === 1 ? "" : "s"))
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.rescanLan()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.switchView(dx)
      }
      onActivateRequested: {
        if (root.flatRows.length > 0)
          root.activate(root.flatRows[root.clamp(root.cursorIndex, 0, root.flatRows.length - 1)])
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") { root.rescanLan(); root.rescanMachine() }
        else if (t === "1") { if (root.view !== "network") root.switchView(1) }
        else if (t === "2") { if (root.view !== "machine") root.switchView(1) }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Port Doctor"
            meta: root.view === "network"
              ? (root.lanNetwork.cidr || "no network") + " · "
                + root.hosts.length + " host" + (root.hosts.length === 1 ? "" : "s") + " · "
                + root.openPorts + " open"
              : (root.machineHostname || "this machine") + " · "
                + root.listeners.length + " listening · "
                + root.connections.length + " live"
            detail: root.scanning && root.view === "network" ? "SCANNING"
              : ageText(root.view === "network" ? root.lanScannedAt : root.machineScannedAt)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display
                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: "\u{F0317}"
                  color: root.hosts.length > 0 ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: "\u{F0450}"
                tooltipText: root.view === "network" ? "Rescan the network" : "Refresh connections"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (root.view === "network") root.rescanLan()
                  else root.rescanMachine()
                }
              }
            }
          }

          // View switch: two pills, keyboard ←/→ or click.
          Rectangle {
            width: parent.width
            implicitHeight: Style.space(30)
            radius: height / 2
            color: root.alpha(root.foreground, 0.05)

            Row {
              anchors.fill: parent
              anchors.margins: Style.space(3)
              spacing: Style.space(3)

              Repeater {
                model: [
                  { id: "network", label: "Network", count: root.hosts.length },
                  { id: "machine", label: "This Mac", count: root.connections.length }
                ]

                Rectangle {
                  required property var modelData
                  readonly property bool activeView: root.view === modelData.id
                  width: (parent.width - Style.space(3)) / 2
                  height: parent.height
                  radius: height / 2
                  color: activeView
                    ? root.alpha(root.accent, 0.22)
                    : (viewHover.containsMouse ? root.alpha(root.foreground, 0.07) : "transparent")

                  Behavior on color { ColorAnimation { duration: 90 } }

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: modelData.label + "  " + modelData.count
                    color: parent.activeView ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: parent.activeView
                  }

                  MouseArea {
                    id: viewHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.view !== modelData.id) root.switchView(1)
                  }
                }
              }
            }
          }

          // Thin activity strip while a scan is in flight.
          Rectangle {
            id: scanStrip
            visible: root.view === "network" && root.scanning
            width: parent.width
            height: Style.space(2)
            radius: height / 2
            color: root.alpha(root.accent, 0.25)
            clip: true

            Rectangle {
              width: scanStrip.width * 0.35
              height: scanStrip.height
              radius: height / 2
              color: root.accent
              SequentialAnimation on x {
                running: scanStrip.visible
                loops: Animation.Infinite
                NumberAnimation { from: 0; to: scanStrip.width * 0.65; duration: 900; easing.type: Easing.InOutCubic }
                NumberAnimation { from: scanStrip.width * 0.65; to: 0; duration: 900; easing.type: Easing.InOutCubic }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.view === "network" && root.lanNetwork.note !== undefined
              && String(root.lanNetwork.note || "") !== ""
            width: parent.width
            text: String(root.lanNetwork.note || "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------- network view

          Column {
            visible: root.view === "network"
            width: parent.width
            spacing: Style.space(6)

            TopologyMap {
              visible: root.hosts.length > 0
              width: parent.width
              hosts: root.hosts
              newIps: root.newIps
              scanning: root.scanning
              selectedIp: {
                if (root.view !== "network") return ""
                var rows = root.flatRows
                if (root.cursorIndex >= 0 && root.cursorIndex < rows.length
                    && rows[root.cursorIndex].kind === "host")
                  return String(rows[root.cursorIndex].host.ip || "")
                return ""
              }
              onHostPicked: function(ip) {
                for (var i = 0; i < root.hosts.length; i++) {
                  if (String(root.hosts[i].ip || "") === ip) {
                    root.keyboardNav = true
                    root.noteCursor(i)
                    root.expandedIp = ip
                    break
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.hosts.length === 0
              width: parent.width
              topPadding: Style.space(20)
              bottomPadding: Style.space(8)
              text: root.lanFailed
                ? "The network scan did not complete.\nR tries again."
                : (root.scanning
                  ? "Listening for hosts on " + (root.lanNetwork.cidr || "the network") + "…"
                  : "No hosts answered yet.\nR rescans.")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.hosts

              HostRow {
                required property var modelData
                required property int index
                width: parent.width
                host: modelData
                expanded: root.expandedIp === String(modelData.ip || "")
                selected: root.cursorIndex === index && root.view === "network"
                isNew: !!root.newIps[String(modelData.ip || "")]
                onActivated: root.activate({ kind: "host", host: modelData })
                onHoveredIndex: {
                  if (Date.now() - root.lastPointerMoveMs < 2500) {
                    root.keyboardNav = false
                    root.noteCursor(index)
                  }
                }
              }
            }
          }

          // ------------------------------------------- machine view

          Column {
            visible: root.view === "machine"
            width: parent.width
            spacing: Style.space(10)

            // Stat tiles: the three numbers that answer "am I exposed?"
            Row {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: [
                  { label: "LISTENING", value: root.listeners.length, tint: root.accent },
                  { label: "TALKING", value: root.connections.length, tint: root.foreground },
                  { label: "LAN PEERS", value: root.lanPeerCount, tint: "#66c2d1" }
                ]

                Rectangle {
                  required property var modelData
                  width: (parent.width - Style.space(16)) / 3
                  implicitHeight: Style.space(56)
                  radius: Style.cornerRadius
                  color: root.alpha(root.foreground, 0.05)

                  Column {
                    anchors.centerIn: parent
                    spacing: Style.space(1)

                    Text {
                      textFormat: Text.PlainText
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: String(modelData.value)
                      color: modelData.tint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.display
                      font.bold: true
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: modelData.label
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.1
                    }
                  }
                }
              }
            }

            // Traffic mix: what fraction of live conversations goes where.
            Column {
              visible: root.kindBreakdown.length > 0
              width: parent.width
              spacing: Style.space(5)

              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: root.alpha(root.foreground, 0.07)
                clip: true

                Row {
                  anchors.fill: parent

                  Repeater {
                    model: root.kindBreakdown

                    Rectangle {
                      required property var modelData
                      width: Math.max(1, modelData.fraction * parent.width)
                      height: parent.height
                      color: modelData.color
                    }
                  }
                }
              }

              Flow {
                width: parent.width
                spacing: Style.space(12)

                Repeater {
                  model: root.kindBreakdown

                  Row {
                    required property var modelData
                    spacing: Style.space(5)

                    Rectangle {
                      width: Style.space(6)
                      height: Style.space(6)
                      radius: width / 2
                      color: modelData.color
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.count + " " + modelData.kind
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            PanelSectionHeader {
              visible: root.listeners.length > 0
              text: "LISTENING ON THIS MAC · " + root.listeners.length
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.listeners

              ListenerRow {
                required property var modelData
                required property int index
                width: parent.width
                listener: modelData
                selected: root.cursorIndex === index && root.view === "machine"
                onHoveredIndex: {
                  if (Date.now() - root.lastPointerMoveMs < 2500) {
                    root.keyboardNav = false
                    root.noteCursor(index)
                  }
                }
              }
            }

            PanelSectionHeader {
              visible: root.connections.length > 0
              text: "TALKING TO · " + root.connections.length
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.connections

              ConnRow {
                required property var modelData
                required property int index
                width: parent.width
                conn: modelData
                selected: root.cursorIndex === (root.listeners.length + index) && root.view === "machine"
                onHoveredIndex: {
                  if (Date.now() - root.lastPointerMoveMs < 2500) {
                    root.keyboardNav = false
                    root.noteCursor(root.listeners.length + index)
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.listeners.length === 0 && root.connections.length === 0
              width: parent.width
              topPadding: Style.space(20)
              bottomPadding: Style.space(8)
              text: root.machineFailed
                ? "This machine's sockets could not be read.\nR tries again."
                : "No sockets on this machine right now."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(2)
            text: "R rescans · ←/→ views · Enter expands · click a node to inspect"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ rows

  // One LAN host: status dot, name and address, service chips, expandable
  // into the full port table with MAC and provenance.
  component HostRow: Item {
    id: hostRow
    property var host: null
    property bool selected: false
    property bool expanded: false
    property bool isNew: false
    signal activated
    signal hoveredIndex

    readonly property var portList: host ? (host.ports || []) : []
    readonly property string displayName: {
      if (!host) return ""
      return String(host.hostname || host.ip || "")
    }
    readonly property string subLine: {
      if (!host) return ""
      var parts = []
      if (String(host.hostname || "") !== "") parts.push(String(host.ip))
      if (String(host.vendor || "") !== "") parts.push(String(host.vendor))
      if (host.latencyMs !== null && host.latencyMs !== undefined)
        parts.push(String(host.latencyMs) + " ms")
      if (portList.length === 0) parts.push("no open ports")
      return parts.join(" · ")
    }

    implicitHeight: rowInner.implicitHeight

    Behavior on implicitHeight { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    onSelectedChanged: if (selected && root.keyboardNav) Qt.callLater(function() {
      var pos = hostRow.mapToItem(column, 0, 0)
      root.scrollTo(pos.y)
    })

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: hostRow.selected
        ? root.alpha(root.foreground, 0.10)
        : (rowHover.containsMouse ? root.alpha(root.foreground, 0.06) : "transparent")

      Behavior on color { ColorAnimation { duration: 90 } }
    }

    // This machine and the gateway get an accent spine instead of a dot:
    // they are the two hosts everyone looks for first.
    Rectangle {
      visible: hostRow.host && (hostRow.host.isSelf || hostRow.host.isGateway)
      width: Style.space(3)
      radius: width / 2
      color: root.accent
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.space(6)
      anchors.bottomMargin: Style.space(6)
    }

    Column {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.topMargin: Style.space(5)
      spacing: Style.space(5)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Rectangle {
          width: Style.space(8)
          height: Style.space(8)
          radius: width / 2
          anchors.verticalCenter: parent.verticalCenter
          color: hostRow.portList.length > 0 ? root.accent : "transparent"
          border.width: hostRow.portList.length > 0 ? 0 : 1
          border.color: root.dim
        }

        Column {
          width: Math.max(Style.space(80),
            parent.width - Style.space(8) - Style.space(10) - chipFlow.width - expandGlyph.width - Style.space(10))
          spacing: Style.space(1)
          anchors.verticalCenter: parent.verticalCenter

          Row {
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: hostRow.displayName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
              maximumLineCount: 1
            }

            Rectangle {
              visible: hostRow.isNew
              implicitWidth: newText.implicitWidth + Style.space(8)
              implicitHeight: newText.implicitHeight + Style.space(2)
              radius: height / 2
              color: root.alpha(root.accent, 0.18)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: newText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "NEW"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Rectangle {
              visible: hostRow.host && (hostRow.host.isSelf || hostRow.host.isGateway)
              implicitWidth: roleText.implicitWidth + Style.space(8)
              implicitHeight: roleText.implicitHeight + Style.space(2)
              radius: height / 2
              color: root.alpha(root.foreground, 0.08)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: roleText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: hostRow.host && hostRow.host.isSelf ? "THIS MAC" : "GATEWAY"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: hostRow.subLine
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Flow {
          id: chipFlow
          readonly property int maxChips: 4
          width: Math.min(implicitWidth, Style.space(180))
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          layoutDirection: Qt.RightToLeft

          Repeater {
            model: hostRow.portList.slice(0, chipFlow.maxChips)

            Rectangle {
              required property var modelData
              readonly property color chipColor: root.classColor(modelData.class)

              implicitWidth: chipText.implicitWidth + Style.space(10)
              implicitHeight: chipText.implicitHeight + Style.space(3)
              radius: height / 2
              color: root.alpha(chipColor, 0.14)

              Text {
                id: chipText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: String(modelData.port) + " " + String(modelData.service)
                color: parent.chipColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Text {
            visible: hostRow.portList.length > chipFlow.maxChips
            textFormat: Text.PlainText
            text: "+" + (hostRow.portList.length - chipFlow.maxChips)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          id: expandGlyph
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: hostRow.expanded ? "▾" : "▸"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Column {
        id: detailColumn
        visible: hostRow.expanded
        width: parent.width
        spacing: Style.space(3)
        leftPadding: Style.space(18)

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          text: {
            if (!hostRow.host) return ""
            var parts = []
            if (String(hostRow.host.mac || "") !== "") parts.push(String(hostRow.host.mac))
            if (String(hostRow.host.vendor || "") !== "") parts.push(String(hostRow.host.vendor))
            parts.push(hostRow.host.via === "neigh" ? "seen in neighbor table" : "answered probes")
            return parts.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width - Style.space(18)
        }

        Repeater {
          model: hostRow.expanded ? hostRow.portList : []

          Row {
            required property var modelData
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(6)
              height: Style.space(6)
              radius: width / 2
              color: root.classColor(modelData.class)
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: String(modelData.port)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              width: Style.space(44)
            }

            Text {
              textFormat: Text.PlainText
              text: String(modelData.service)
              color: root.classColor(modelData.class)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: Style.space(72)
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: String(modelData.proto) + " · " + String(modelData.class)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: hostRow.hoveredIndex()
      onPositionChanged: root.lastPointerMoveMs = Date.now()
      onClicked: hostRow.activated()
    }
  }

  // One listening socket: what service this machine offers, and to whom.
  component ListenerRow: Item {
    id: listenRow
    property var listener: null
    property bool selected: false
    signal hoveredIndex

    readonly property int port: listener ? Number(listener.port || 0) : 0
    readonly property string serviceName: {
      if (!listener) return ""
      var s = String(listener.service || "")
      return s !== "" ? s : String(listener.proto)
    }
    readonly property string serviceClass: listener ? String(listener.class || "unknown") : "unknown"
    readonly property bool lanExposed: listener && String(listener.scope) === "all interfaces"

    implicitHeight: Style.space(30)

    onSelectedChanged: if (selected && root.keyboardNav) Qt.callLater(function() {
      var pos = listenRow.mapToItem(column, 0, 0)
      root.scrollTo(pos.y)
    })

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: listenRow.selected
        ? root.alpha(root.foreground, 0.10)
        : (listenHover.containsMouse ? root.alpha(root.foreground, 0.06) : "transparent")
      Behavior on color { ColorAnimation { duration: 90 } }
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: listenRow.port > 0 ? String(listenRow.port) : "·"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        width: Style.space(52)
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: Math.max(Style.space(60), parent.width - Style.space(52)
          - scopePill.width - Style.space(10) * 2)
        spacing: Style.space(1)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: listenRow.listener && String(listenRow.listener.process || "") !== ""
            ? String(listenRow.listener.process)
            : listenRow.serviceName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: (listenRow.listener ? String(listenRow.listener.proto) : "")
            + " · " + listenRow.serviceName
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Rectangle {
        id: scopePill
        implicitWidth: scopeText.implicitWidth + Style.space(10)
        implicitHeight: scopeText.implicitHeight + Style.space(3)
        radius: height / 2
        color: listenRow.lanExposed ? root.alpha(root.accent, 0.16) : root.alpha(root.foreground, 0.07)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: scopeText
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: listenRow.listener ? String(listenRow.listener.scope) : ""
          color: listenRow.lanExposed ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    MouseArea {
      id: listenHover
      anchors.fill: parent
      hoverEnabled: true
      onEntered: listenRow.hoveredIndex()
      onPositionChanged: root.lastPointerMoveMs = Date.now()
    }

    PanelToolTip {
      visible: listenHover.containsMouse && listenRow.listener
      fontFamily: root.fontFamily
      text: {
        if (!listenRow.listener) return ""
        var lines = []
        lines.push("port " + listenRow.port + " (" + String(listenRow.listener.proto) + ")")
        lines.push("bound to " + String(listenRow.listener.bind))
        if (String(listenRow.listener.process || "") !== "")
          lines.push("process " + String(listenRow.listener.process)
            + (listenRow.listener.pid ? " · pid " + listenRow.listener.pid : ""))
        else
          lines.push("owned by another account or the system")
        var scope = String(listenRow.listener.scope)
        if (scope === "all interfaces") lines.push("reachable from any network this machine joins")
        else if (scope === "loopback only") lines.push("not reachable from the network")
        else lines.push("reachable on its bound interface only")
        return lines.join("\n")
      }
    }
  }

  // One live connection: process, peer, where the peer lives.
  component ConnRow: Item {
    id: connRow
    property var conn: null
    property bool selected: false
    signal hoveredIndex

    readonly property color kindColor: {
      if (!conn) return root.dim
      switch (String(conn.remoteKind)) {
        case "lan": return root.accent
        case "private": return "#66c2d1"
        case "internet": return root.foreground
        default: return root.dim
      }
    }
    readonly property string peer: {
      if (!conn) return ""
      var name = String(conn.remoteName || "")
      var base = name !== "" ? name : String(conn.remoteIp)
      return base + ":" + conn.remotePort
    }

    implicitHeight: Style.space(30)

    onSelectedChanged: if (selected && root.keyboardNav) Qt.callLater(function() {
      var pos = connRow.mapToItem(column, 0, 0)
      root.scrollTo(pos.y)
    })

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: connRow.selected
        ? root.alpha(root.foreground, 0.10)
        : (connHover.containsMouse ? root.alpha(root.foreground, 0.06) : "transparent")
      Behavior on color { ColorAnimation { duration: 90 } }
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Rectangle {
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        color: connRow.kindColor
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: connRow.conn && String(connRow.conn.process || "") !== ""
          ? String(connRow.conn.process)
          : "system"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        width: Style.space(110)
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: "→"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: Math.max(Style.space(80), parent.width - Style.space(8) - Style.space(110)
          - stateText.width - kindText.width - Style.space(10) * 4)
        spacing: Style.space(1)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: connRow.peer
          color: connRow.kindColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: connRow.conn && String(connRow.conn.remoteName || "") !== ""
          text: connRow.conn ? String(connRow.conn.remoteIp) + ":" + connRow.conn.remotePort : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: stateText
        textFormat: Text.PlainText
        text: connRow.conn ? String(connRow.conn.state) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: kindText
        textFormat: Text.PlainText
        text: connRow.conn ? String(connRow.conn.remoteKind).toUpperCase() : ""
        color: connRow.kindColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: connHover
      anchors.fill: parent
      hoverEnabled: true
      onEntered: connRow.hoveredIndex()
      onPositionChanged: root.lastPointerMoveMs = Date.now()
    }

    PanelToolTip {
      visible: connHover.containsMouse && connRow.conn
      fontFamily: root.fontFamily
      text: {
        if (!connRow.conn) return ""
        var c = connRow.conn
        var lines = []
        lines.push(String(c.proto) + " " + String(c.localIp) + ":" + c.localPort
          + " ↔ " + String(c.remoteIp) + ":" + c.remotePort)
        lines.push("state " + String(c.state))
        if (String(c.process || "") !== "")
          lines.push("process " + String(c.process) + (c.pid ? " · pid " + c.pid : ""))
        else
          lines.push("owned by another account or the system")
        return lines.join("\n")
      }
    }
  }

  readonly property int lanPeerCount: {
    var seen = {}
    var n = 0
    for (var i = 0; i < connections.length; i++) {
      var c = connections[i]
      if (c.remoteKind === "lan" && !seen[c.remoteIp]) { seen[c.remoteIp] = true; n++ }
    }
    return n
  }

  readonly property var kindBreakdown: {
    var counts = {}
    var total = 0
    for (var i = 0; i < connections.length; i++) {
      var k = String(connections[i].remoteKind || "unknown")
      counts[k] = (counts[k] || 0) + 1
      total++
    }
    var order = [["lan", accent], ["private", "#66c2d1"],
                 ["internet", alpha(foreground, 0.55)], ["loopback", dim]]
    var out = []
    for (var j = 0; j < order.length; j++)
      if (counts[order[j][0]])
        out.push({ kind: order[j][0], count: counts[order[j][0]],
                   color: order[j][1], fraction: counts[order[j][0]] / Math.max(1, total) })
    return out
  }

  // ------------------------------------------------- radial network map

  // The map draws what the scan measured: this machine at the center, one
  // spoke per answering host, gateway riding close to the core. Node size
  // grows with open-port count; the ring takes the host's dominant service
  // class. Newly arrived hosts pulse once per second until the next scan.
  component TopologyMap: Item {
    id: map
    property var hosts: []
    property var newIps: ({})
    property string selectedIp: ""
    property bool scanning: false
    signal hostPicked(string ip)

    implicitHeight: Style.space(216)
    property var nodes: []
    property string hoverIp: ""
    property real pulseT: 0
    property real sweepAngle: 0

    function layout() {
      var w = width, h = implicitHeight
      if (w < 10 || !hosts) { nodes = []; return }
      var cx = w / 2, cy = h * 0.54
      var self = null, gateway = null, others = []
      for (var i = 0; i < hosts.length; i++) {
        var host = hosts[i]
        if (host.isSelf) self = host
        else if (host.isGateway) gateway = host
        else others.push(host)
      }
      var placed = []
      var rx = Math.max(Style.space(120), w * 0.40)
      var ry = h * 0.36
      var n = others.length
      for (var j = 0; j < n; j++) {
        // Two concentric orbits when the ring would crowd: even indices in.
        var inner = n > 10 && (j % 2 === 0)
        var ringCount = n > 10 ? Math.ceil(n / 2) : n
        var slot = n > 10 ? Math.floor(j / 2) : j
        var total = n > 10 ? (inner ? Math.ceil(n / 2) : Math.floor(n / 2)) : n
        var angle = -Math.PI / 2 + (total > 0 ? (2 * Math.PI * slot / total) : 0)
          + (inner ? 0 : Math.PI / Math.max(1, total))
        var frx = inner ? rx * 0.62 : rx
        var fry = inner ? ry * 0.60 : ry
        placed.push({ host: others[j], x: cx + Math.cos(angle) * frx,
                      y: cy + Math.sin(angle) * fry })
      }
      var list = []
      if (gateway) list.push({ host: gateway, x: cx, y: cy - ry * 0.42,
                               r: Style.space(8), role: "gateway" })
      for (var m = 0; m < placed.length; m++) {
        var p = placed[m]
        var pc = (p.host.ports || []).length
        list.push({ host: p.host, x: p.x, y: p.y,
                    r: Style.space(5) + Math.min(pc, 10) * Style.spaceReal(1.1),
                    role: "host" })
      }
      if (self) list.push({ host: self, x: cx, y: cy, r: Style.space(11),
                            role: "self" })
      nodes = list
      canvas.requestPaint()
    }

    onHostsChanged: layout()
    onWidthChanged: layout()
    Component.onCompleted: layout()

    NumberAnimation on pulseT {
      from: 0; to: 1; duration: 1600; loops: Animation.Infinite
      running: true
    }
    NumberAnimation on sweepAngle {
      from: 0; to: 2 * Math.PI; duration: 2200; loops: Animation.Infinite
      running: map.scanning
    }

    Canvas {
      id: canvas
      anchors.fill: parent
      onPaint: {
        var c = getContext("2d")
        c.reset()
        var ns = map.nodes
        var cx = width / 2, cy = height * 0.54
        var fg = root.foreground, ac = root.accent

        // Spokes first, nodes on top.
        for (var i = 0; i < ns.length; i++) {
          var nd = ns[i]
          if (nd.role === "self") continue
          c.beginPath()
          c.moveTo(cx, cy)
          c.lineTo(nd.x, nd.y)
          c.strokeStyle = root.alpha(fg, nd.role === "gateway" ? 0.30 : 0.10)
          c.lineWidth = nd.role === "gateway" ? 1.6 : 1
          c.stroke()
        }

        // Radar sweep while a scan is in flight.
        if (map.scanning) {
          c.beginPath()
          c.moveTo(cx, cy)
          c.arc(cx, cy, Math.min(width, height) * 0.44, map.sweepAngle, map.sweepAngle + 0.55)
          c.closePath()
          c.fillStyle = root.alpha(ac, 0.05)
          c.fill()
          c.beginPath()
          c.moveTo(cx, cy)
          c.lineTo(cx + Math.cos(map.sweepAngle) * Math.min(width, height) * 0.44,
                   cy + Math.sin(map.sweepAngle) * Math.min(width, height) * 0.44)
          c.strokeStyle = root.alpha(ac, 0.35)
          c.lineWidth = 1
          c.stroke()
        }

        for (var k = 0; k < ns.length; k++) {
          var node = ns[k]
          var host = node.host
          var ports = (host.ports || []).length
          var ip = String(host.ip || "")
          var dominant = ports > 0 ? root.classColor(host.ports[0].class) : null

          if (map.newIps[ip]) {
            c.beginPath()
            c.arc(node.x, node.y, node.r + map.pulseT * Style.space(9), 0, Math.PI * 2)
            c.strokeStyle = root.alpha(ac, (1 - map.pulseT) * 0.55)
            c.lineWidth = 1.4
            c.stroke()
          }

          c.beginPath()
          c.arc(node.x, node.y, node.r, 0, Math.PI * 2)
          if (node.role === "self") {
            c.fillStyle = ac
          } else if (ports > 0) {
            c.fillStyle = root.alpha(dominant || ac, 0.85)
          } else {
            c.fillStyle = root.alpha(fg, 0.22)
          }
          c.fill()
          if (node.role === "gateway") {
            c.strokeStyle = root.alpha(ac, 0.9)
            c.lineWidth = 1.6
            c.stroke()
          } else if (dominant) {
            c.strokeStyle = root.alpha(dominant, 0.5)
            c.lineWidth = 1.2
            c.stroke()
          }

          if (ip === map.selectedIp || ip === map.hoverIp) {
            c.beginPath()
            c.arc(node.x, node.y, node.r + Style.space(4), 0, Math.PI * 2)
            c.strokeStyle = root.alpha(ac, ip === map.selectedIp ? 0.95 : 0.45)
            c.lineWidth = 1.4
            c.stroke()
          }
        }
      }
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
    }

    // Nodes repaint on state changes.
    onSelectedIpChanged: canvas.requestPaint()
    onHoverIpChanged: canvas.requestPaint()
    onPulseTChanged: canvas.requestPaint()
    onSweepAngleChanged: if (map.scanning) canvas.requestPaint()

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: map.hoverIp !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      function nodeAt(mx, my) {
        var best = "", bestD = 1e9
        for (var i = 0; i < map.nodes.length; i++) {
          var nd = map.nodes[i]
          var d = Math.hypot(nd.x - mx, nd.y - my)
          var hit = Math.max(Style.space(12), nd.r + Style.space(6))
          if (d < hit && d < bestD) { bestD = d; best = String(nd.host.ip || "") }
        }
        return best
      }
      onPositionChanged: function(mouse) {
        map.hoverIp = nodeAt(mouse.x, mouse.y)
      }
      onExited: map.hoverIp = ""
      onClicked: function(mouse) {
        var ip = nodeAt(mouse.x, mouse.y)
        if (ip !== "") map.hostPicked(ip)
      }
    }

    // Hover/selection readout under the map: honest text, no overlay fights.
    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      horizontalAlignment: Text.AlignHCenter
      property var shown: {
        var ip = map.hoverIp !== "" ? map.hoverIp : map.selectedIp
        for (var i = 0; i < map.hosts.length; i++)
          if (String(map.hosts[i].ip || "") === ip) return map.hosts[i]
        return null
      }
      text: {
        if (!shown) return ""
        var parts = []
        if (String(shown.hostname || "") !== "") parts.push(String(shown.hostname))
        parts.push(String(shown.ip))
        var ports = shown.ports || []
        if (ports.length > 0) {
          var names = []
          for (var i = 0; i < Math.min(ports.length, 4); i++) names.push(String(ports[i].service))
          parts.push(names.join(", ") + (ports.length > 4 ? " +" + (ports.length - 4) : ""))
        }
        if (String(shown.vendor || "") !== "") parts.push(String(shown.vendor))
        return parts.join("  ·  ")
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
