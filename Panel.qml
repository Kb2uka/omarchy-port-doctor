import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Palette.js" as P

Panel {
  id: root
  moduleName: "kb2uka.port-doctor"
  ipcTarget: "kb2uka.port-doctor"

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- model

  readonly property string scannerPath: decodeURIComponent(
    Qt.resolvedUrl("port-doctor.py").toString().replace(/^file:\/\//, ""))
  readonly property int pollMs: {
    var v = Number(setting("scanIntervalSec", 300))
    return (isFinite(v) && v >= 30 && v <= 3600 ? Math.round(v) : 300) * 1000
  }

  property var hostsAll: []          // online rows + offline baseline rows
  property var lastSeen: ({})        // ip -> ISO timestamp last observed
  property var hostCache: ({})       // ip -> last full record (name/vendor/mac)
  property var lanNetwork: ({})
  property var lanStats: ({})
  property string lanScannedAt: ""
  property bool lanFailed: false
  property string profile: "standard"
  property var history: []
  property var newIps: ({})

  property var listeners: []
  property var connections: []
  property var machineStats: ({})
  property string machineScannedAt: ""
  property bool machineFailed: false
  property string machineHostname: ""

  readonly property bool scanning: lanProcess.running
  readonly property int onlineCount: lanStats.hostsUp || 0
  readonly property int openPorts: lanStats.openPorts || 0

  function rescanLan() {
    if (!lanProcess.running) {
      lanProcess.command = ["/usr/bin/python3", "-I", "-B", scannerPath,
                            profile === "quick" ? "lan-quick" : "lan"]
      lanProcess.running = true
    }
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

  // A scan wedged on a stuck resolver must not pin the window in "scanning".
  Timer {
    interval: 16000
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

  Timer {
    interval: root.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.rescanLan()
  }

  Timer {
    interval: 2500
    running: root.opened
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
    // A failed scan keeps the last good view and the NEW baseline.
    if (payload.error) { lanFailed = true; return }
    lanFailed = false
    lanScannedAt = String(payload.scannedAt || "")
    lanNetwork = payload.network || ({})
    lanStats = payload.stats || ({})

    var incoming = payload.hosts
    var seen = {}
    var fresh = {}
    var hadBaseline = false
    for (var k in lastSeen) hadBaseline = true
    for (var i = 0; i < incoming.length; i++) {
      var h = incoming[i]
      var ip = String(h.ip || "")
      if (ip === "") continue
      h.online = true
      h.lastSeen = lanScannedAt
      seen[ip] = true
      if (hadBaseline && !lastSeen[ip]) fresh[ip] = true
      lastSeen[ip] = lanScannedAt
      hostCache[ip] = h
    }
    // Offline: known before, silent now. Rows keep their last identity.
    var merged = []
    for (var j = 0; j < incoming.length; j++) merged.push(incoming[j])
    for (var knownIp in lastSeen) {
      if (seen[knownIp]) continue
      var prior = hostCache[knownIp] || {}
      merged.push({
        ip: knownIp,
        hostname: String(prior.hostname || ""),
        mac: String(prior.mac || ""),
        vendor: String(prior.vendor || ""),
        type: String(prior.type || "unknown"),
        isSelf: false, isGateway: false,
        via: "scan", latencyMs: null, ports: [],
        online: false, lastSeen: lastSeen[knownIp]
      })
    }
    merged.sort(function(a, b) {
      var pa = String(a.ip).split("."), pb = String(b.ip).split(".")
      for (var o = 0; o < 4; o++) {
        var d = (parseInt(pa[o], 10) || 0) - (parseInt(pb[o], 10) || 0)
        if (d !== 0) return d
      }
      return 0
    })
    newIps = fresh
    hostsAll = merged
    lastSeen = lastSeen
    hostCache = hostCache

    var entry = {
      at: lanScannedAt,
      profile: String(payload.profile || profile),
      hostsUp: lanStats.hostsUp || 0,
      openPorts: lanStats.openPorts || 0,
      scanMs: lanStats.scanMs || 0
    }
    var next = history.slice()
    next.unshift(entry)
    history = next.slice(0, 30)
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
    if (payload.error) { machineFailed = true; return }
    machineFailed = false
    machineScannedAt = String(payload.scannedAt || "")
    machineHostname = String(payload.hostname || "")
    machineStats = payload.stats || ({})
    listeners = payload.listeners
    connections = payload.connections || []
  }

  // ------------------------------------------------------------- shell

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0317}"
    active: root.hostsAll.length > 0 || root.scanning
    tooltipText: root.scanning
      ? "Port Doctor · scanning " + (root.lanNetwork.cidr || "network") + "…"
      : (root.lanFailed
        ? "Port Doctor · scan failed"
        : "Port Doctor · " + root.onlineCount + " hosts · " + root.openPorts + " open ports")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.rescanLan()
      else root.toggle()
    }
  }

  FloatingWindow {
    id: window
    title: "Port Doctor"
    visible: root.opened
    implicitWidth: 1280
    implicitHeight: 820
    minimumSize: Qt.size(1080, 680)
    color: P.background
    onVisibleChanged: if (!visible && root.opened) root.close()

    AppView {
      id: appView
      anchors.fill: parent
      fontMono: root.fontFamily
      hosts: root.hostsAll
      network: root.lanNetwork
      scannedAt: root.lanScannedAt
      scanning: root.scanning
      scanFailed: root.lanFailed
      profile: root.profile
      history: root.history
      newIps: root.newIps
      listeners: root.listeners
      connections: root.connections
      machineHostname: root.machineHostname
      machineScannedAt: root.machineScannedAt
      machineFailed: root.machineFailed
      onProfileSelected: root.profile = profile
      onRescanRequested: root.rescanLan()
      onRescanMachineRequested: root.rescanMachine()
      onCloseRequested: root.close()
    }
  }

  // Test/debug hook: switch the window's page from outside.
  function setPage(page) {
    appView.page = page
  }
}
