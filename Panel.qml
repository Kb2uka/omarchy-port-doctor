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
    lanFailed = !!payload.error
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

  function classColor(klass) {
    switch (String(klass)) {
      case "remote": return "#5b8def"
      case "web": return "#3fa97c"
      case "media": return "#9b8cff"
      case "file": return "#e5c07b"
      case "print": return "#9aa7b0"
      case "iot": return "#f2789f"
      case "db": return "#f2a154"
      case "mail": return "#66c2d1"
      case "infra": return "#a5b4fc"
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
    text: "\u{F6FF}"
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
                  text: "\u{F6FF}"
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
                    root.cursorIndex = index
                  }
                }
              }
            }
          }

          // ------------------------------------------- machine view

          Column {
            visible: root.view === "machine"
            width: parent.width
            spacing: Style.space(6)

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
                    root.cursorIndex = index
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
                    root.cursorIndex = root.listeners.length + index
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
            text: "R rescans · ←/→ views · Enter expands a host"
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

    implicitHeight: rowInner.implicitHeight + (expanded ? detailColumn.implicitHeight + Style.space(8) : 0)

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
      var known = root.serviceForPort(port)
      return known !== "" ? known : String(listener.proto)
    }
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
        lines.push(listenRow.lanExposed ? "reachable from the network" : "not reachable from the network")
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

  // Port -> service name for this machine's sockets (mirrors the scanner's
  // curated table; unknown ports stay honest).
  function serviceForPort(port) {
    switch (port) {
      case 21: return "ftp"
      case 22: return "ssh"
      case 23: return "telnet"
      case 25: return "smtp"
      case 53: return "dns"
      case 80: return "http"
      case 110: return "pop3"
      case 139: return "netbios"
      case 143: return "imap"
      case 443: return "https"
      case 445: return "smb"
      case 631: return "ipp"
      case 993: return "imaps"
      case 995: return "pop3s"
      case 1883: return "mqtt"
      case 3000: return "dev-http"
      case 3306: return "mysql"
      case 3389: return "rdp"
      case 5000: return "dev-http"
      case 5432: return "postgres"
      case 5900: return "vnc"
      case 6379: return "redis"
      case 7000: return "airplay"
      case 8000: return "http-alt"
      case 8009: return "cast"
      case 8080: return "http-alt"
      case 8443: return "https-alt"
      case 8883: return "mqtts"
      case 9100: return "jetdirect"
      case 32400: return "plex"
      case 8096: return "jellyfin"
      default: return ""
    }
  }
}
