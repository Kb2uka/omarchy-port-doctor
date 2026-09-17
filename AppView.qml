import QtQuick
import QtQuick.Controls
import qs.Commons
import "Palette.js" as P

// The Port Doctor window: navigation rail, header, page router. All network
// data arrives as bound properties from Panel.qml; this file owns only
// presentation state (page, search, topology mode).
Rectangle {
  id: root
  color: P.background

  property string fontMono: Style.font.family

  property var hosts: []
  property var network: ({})
  property var identity: ({})
  property var controller: ({})
  property string scannedAt: ""
  property bool scanning: false
  property bool scanFailed: false
  property string profile: "standard"
  property var history: []
  property var newIps: ({})

  property var listeners: []
  property var connections: []
  property string machineHostname: ""
  property string machineScannedAt: ""
  property bool machineFailed: false

  signal rescanRequested
  signal rescanMachineRequested
  signal closeRequested
  signal profileSelected(string profile)

  property string page: "topology"
  property string topoMode: "map"
  property string searchText: ""
  property string selectedIp: ""

  // What this machine is called: its real hostname (or model) from the
  // scanner's identity block; empty until the first payload lands. The
  // machine payload's hostname is the last fallback so an older or
  // partial identity block still yields the real name.
  readonly property string selfName: String(identity.label || identity.hostname || machineHostname || "")

  focus: true
  Keys.onEscapePressed: root.closeRequested()
  Keys.onPressed: function(event) {
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
      topBar.focusSearch()
      event.accepted = true
    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_R) {
      root.rescanRequested()
      event.accepted = true
    }
  }

  readonly property var visibleHosts: {
    var q = searchText.trim().toLowerCase()
    if (q === "") return hosts
    var out = []
    for (var i = 0; i < hosts.length; i++) {
      var h = hosts[i]
      var hay = (String(h.ip) + " " + String(h.hostname || "") + " "
                 + String(h.vendor || "") + " " + String(h.type || "") + " "
                 + String(h.network || "")).toLowerCase()
      var ports = h.ports || []
      for (var j = 0; j < ports.length; j++)
        hay += " " + ports[j].port + " " + String(ports[j].service || "").toLowerCase()
      if (hay.indexOf(q) >= 0) out.push(h)
    }
    return out
  }

  readonly property var onlineHosts: {
    var out = []
    for (var i = 0; i < hosts.length; i++) if (hosts[i].online) out.push(hosts[i])
    return out
  }

  readonly property var onlineVisibleHosts: {
    var out = []
    for (var i = 0; i < visibleHosts.length; i++)
      if (visibleHosts[i].online) out.push(visibleHosts[i])
    return out
  }

  readonly property int totalOpenPorts: {
    var n = 0
    for (var i = 0; i < onlineHosts.length; i++) n += (onlineHosts[i].ports || []).length
    return n
  }

  // Distinct controller-labelled networks in view; 1 means "only the
  // local subnet is known", so the header stays quiet.
  readonly property int networkCount: {
    var seen = {}
    var n = 0
    for (var i = 0; i < hosts.length; i++) {
      var name = String(hosts[i].network || "")
      if (name !== "" && !seen[name]) { seen[name] = true; n++ }
    }
    return Math.max(1, n)
  }

  Row {
    anchors.fill: parent

    Sidebar {
      width: root.width < 940 ? 56 : (root.width < 1160 ? 168 : 196)
      height: parent.height
      fontMono: root.fontMono
      page: root.page
      profile: root.profile
      lastScanAt: root.scannedAt
      scanning: root.scanning
      compact: root.width < 1160
      rail: root.width < 940
      selfName: root.selfName
      onNavigate: function(page) { root.page = page }
      onProfileSelected: root.profileSelected(profile)
      onScanRequested: root.rescanRequested()
    }

    Rectangle {
      width: 1
      height: parent.height
      color: P.border
    }

    Column {
      width: parent.width - sidebarWidth - 1
      height: parent.height
      property int sidebarWidth: root.width < 940 ? 56 : (root.width < 1160 ? 168 : 196)

      TopBar {
        id: topBar
        width: parent.width
        fontMono: root.fontMono
        network: root.network
        hostsOnline: root.onlineHosts.length
        hostsTotal: root.hosts.length
        openPorts: root.totalOpenPorts
        networkCount: root.networkCount
        scannedAt: root.scannedAt
        scanning: root.scanning
        page: root.page
        topoMode: root.topoMode
        searchText: root.searchText
        onSearchEdited: function(text) { root.searchText = text }
        onTopoModeSelected: function(mode) { root.topoMode = mode }
        onNavigate: function(page) { root.page = page }
        onRescanRequested: root.rescanRequested()
      }

      Rectangle {
        width: parent.width
        height: 1
        color: P.border
      }

      // Scan progress line under the header.
      Rectangle {
        visible: root.scanning
        width: parent.width
        height: 2
        color: P.alpha(P.accent, 0.18)
        Rectangle {
          id: progressRunner
          width: parent.width * 0.28
          height: 2
          color: P.accent
          SequentialAnimation on x {
            running: root.scanning
            loops: Animation.Infinite
            NumberAnimation { from: 0; to: progressRunner.parent.width - progressRunner.width; duration: 1100; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0; duration: 1100; easing.type: Easing.InOutQuad }
          }
        }
      }

      Item {
        width: parent.width
        height: parent.height - topBar.height - 1 - (root.scanning ? 2 : 0)

        TopologyView {
          anchors.fill: parent
          visible: root.page === "topology"
          fontMono: root.fontMono
          hosts: root.visibleHosts
          onlineOnly: true
          network: root.network
          selfName: root.selfName
          scanning: root.scanning
          scanFailed: root.scanFailed
          newIps: root.newIps
          mode: root.topoMode
          selectedIp: root.selectedIp
          onHostSelected: function(ip) { root.selectedIp = ip }
        }

        DevicesView {
          anchors.fill: parent
          visible: root.page === "devices"
          fontMono: root.fontMono
          hosts: root.visibleHosts
          selfName: root.selfName
          onHostSelected: function(ip) { root.selectedIp = ip }
        }

        PortsView {
          anchors.fill: parent
          visible: root.page === "ports"
          fontMono: root.fontMono
          hosts: root.onlineVisibleHosts
        }

        ServicesView {
          anchors.fill: parent
          visible: root.page === "services"
          fontMono: root.fontMono
          hosts: root.onlineVisibleHosts
        }

        MachineView {
          anchors.fill: parent
          visible: root.page === "machine"
          fontMono: root.fontMono
          hostname: root.machineHostname
          identity: root.identity
          listeners: root.listeners
          connections: root.connections
          scannedAt: root.machineScannedAt
          failed: root.machineFailed
          onRefreshRequested: root.rescanMachineRequested()
        }

        WatchView {
          anchors.fill: parent
          visible: root.page === "watch"
          fontMono: root.fontMono
          hosts: root.onlineHosts
          network: root.network
        }

        HistoryView {
          anchors.fill: parent
          visible: root.page === "history"
          fontMono: root.fontMono
          history: root.history
        }

        SettingsView {
          anchors.fill: parent
          visible: root.page === "settings"
          fontMono: root.fontMono
          profile: root.profile
          network: root.network
          controller: root.controller
          onProfileSelected: root.profileSelected(profile)
        }
      }
    }
  }
}
