import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// Network map: gateway at the center, one node per device with a type icon,
// subtle links between them. Hosts the controller reported on other
// networks orbit outside the local ring on dashed routed links. Map is one
// of three presentations (map, list, table) switched by the header control.
Item {
  id: root
  property string fontMono: "monospace"
  property var hosts: []          // search-filtered, all rows
  property bool onlineOnly: true  // the map draws online hosts only
  property var network: ({})
  property string selfName: ""
  property bool scanning: false
  property bool scanFailed: false
  property var newIps: ({})
  property string mode: "map"
  property string selectedIp: ""
  signal hostSelected(string ip)

  readonly property var mapHosts: {
    var out = []
    for (var i = 0; i < hosts.length; i++)
      if (hosts[i].online) out.push(hosts[i])
    return out
  }

  function hostLabel(host) {
    if (host.isSelf) return root.selfName !== "" ? root.selfName : "This machine"
    var nm = String(host.hostname || "")
    if (nm !== "") return nm.replace(/\.local$/, "")
    if (host.isGateway) return "Gateway"
    return String(host.vendor || "")
  }

  // ---------------------------------------------------------- geometry
  // Gateway at center; local devices on one or two orbits, remote-network
  // devices on an outer orbit of their own. Angles are stable per list
  // order so nodes do not jump between scans.
  property var nodePlacements: []

  function layout() {
    var w = mapArea.width, h = mapArea.height
    if (w < 100 || h < 100) return
    var cx = w / 2, cy = h / 2 - 6
    var self = null, gateway = null, locals = [], remotes = []
    var list = mapHosts
    for (var i = 0; i < list.length; i++) {
      var hst = list[i]
      if (hst.isSelf) self = hst
      else if (hst.isGateway) gateway = hst
      else if (hst.remoteNet === true) remotes.push(hst)
      else locals.push(hst)
    }
    var placed = []
    var n = locals.length
    var baseRx = Math.min(w * 0.38, Math.max(210, n * 26))
    var baseRy = Math.min(h * 0.36, Math.max(120, n * 13))
    var twoRings = n > 10
    for (var j = 0; j < n; j++) {
      var inner = twoRings && (j % 2 === 0)
      var total = twoRings ? (inner ? Math.ceil(n / 2) : Math.floor(n / 2)) : n
      var slot = twoRings ? Math.floor(j / 2) : j
      var angle = -Math.PI / 2 + (total > 0 ? (2 * Math.PI * slot / total) : 0)
        + ((twoRings && !inner) ? Math.PI / Math.max(1, total) : 0)
      var rx = inner ? baseRx * 0.60 : baseRx
      var ry = inner ? baseRy * 0.58 : baseRy
      placed.push({ host: locals[j],
                    x: cx + Math.cos(angle) * rx,
                    y: cy + Math.sin(angle) * ry })
    }
    // Remote (other-network) hosts: their own outer orbit.
    var rn = remotes.length
    var rxOuter = Math.min(w * 0.47, baseRx + 96)
    var ryOuter = Math.min(h * 0.45, baseRy + 76)
    for (var r = 0; r < rn; r++) {
      var rAngle = -Math.PI / 2 + (2 * Math.PI * r / rn) + Math.PI / Math.max(1, rn)
      placed.push({ host: remotes[r],
                    x: cx + Math.cos(rAngle) * rxOuter,
                    y: cy + Math.sin(rAngle) * ryOuter })
    }
    var result = []
    if (gateway) result.push({ host: gateway, x: cx, y: cy, big: true })
    for (var m = 0; m < placed.length; m++)
      result.push({ host: placed[m].host, x: placed[m].x, y: placed[m].y, big: false })
    if (self) result.push({ host: self, x: cx, y: cy + Math.min(h * 0.30, 150), big: true })
    nodePlacements = result
    linksCanvas.requestPaint()
  }

  onModeChanged: if (mode === "map") layout()
  onHostsChanged: layout()
  onSelectedIpChanged: linksCanvas.requestPaint()

  // ---------------------------------------------------------- views
  Item {
    visible: root.mode === "map"
    anchors.fill: parent

    Item {
      id: mapArea
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Math.max(320, parent.height * 0.58)
      onWidthChanged: root.layout()
      onHeightChanged: root.layout()
      Component.onCompleted: root.layout()

      Canvas {
        id: linksCanvas
        anchors.fill: parent
        onPaint: {
          var c = getContext("2d")
          c.reset()
          var ns = root.nodePlacements
          var core = null
          for (var i = 0; i < ns.length; i++)
            if (ns[i].host.isGateway) { core = ns[i]; break }
          if (!core && ns.length > 0) core = ns[ns.length - 1]  // self as hub
          if (!core) return
          for (var k = 0; k < ns.length; k++) {
            var nd = ns[k]
            if (nd === core) continue
            var ip = String(nd.host.ip || "")
            var hot = (ip === root.selectedIp || ip === mapHover.hoverIp)
            var routed = nd.host.remoteNet === true
            c.beginPath()
            c.moveTo(core.x, core.y)
            // Gentle curve: control point nudged perpendicular to the chord.
            var mx = (core.x + nd.x) / 2, my = (core.y + nd.y) / 2
            var dx = nd.x - core.x, dy = nd.y - core.y
            var len = Math.max(1, Math.sqrt(dx * dx + dy * dy))
            c.quadraticCurveTo(mx - dy * 0.06, my + dx * 0.06, nd.x, nd.y)
            // A dashed link is a routed path: the host lives on another
            // network and everything to it goes through the gateway.
            c.setLineDash(routed && !hot ? [4, 4] : [])
            c.strokeStyle = hot ? P.alpha(P.teal, 0.75)
              : (nd.host.isSelf ? P.alpha(P.accent, 0.45)
              : (routed ? P.alpha(P.blue, 0.5) : P.alpha("#3c5268", 0.55)))
            c.lineWidth = hot ? 1.6 : 1.1
            c.stroke()
          }
          c.setLineDash([])
        }
      }

      Repeater {
        model: root.nodePlacements

        Item {
          required property var modelData
          readonly property var host: modelData.host
          readonly property string ip: String(host.ip || "")
          readonly property bool selected: root.selectedIp === ip
          readonly property bool hovered: mapHover.hoverIp === ip
          readonly property int portCount: (host.ports || []).length
          readonly property int nodeSize: modelData.big ? 64 : 52

          x: modelData.x - nodeSize / 2
          y: modelData.y - nodeSize / 2
          width: nodeSize
          height: nodeSize + 34

          Rectangle {
            width: parent.nodeSize
            height: parent.nodeSize
            radius: width / 2
            color: parent.selected ? P.raised : (parent.hovered ? P.hover : P.surface)
            border.width: parent.host.isGateway ? 2 : 1.4
            border.color: parent.host.isGateway ? P.accent
              : (parent.selected ? P.blue : (parent.hovered ? P.teal : P.borderStrong))
            Behavior on border.color { ColorAnimation { duration: 90 } }

            DeviceIcon {
              anchors.centerIn: parent
              type: parent.parent.host.type || "unknown"
              ink: parent.parent.host.isGateway ? P.accent
                : (parent.parent.portCount > 0 ? P.text : P.secondary)
              glyphSize: parent.parent.nodeSize * 0.44
              fontFamily: root.fontMono
            }
          }

          StatusDot {
            online: true
            x: parent.width - 14
            y: 2
          }

          Column {
            anchors.top: parent.top
            anchors.topMargin: parent.nodeSize + 5
            width: 116
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 1

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: parent.parent.ip
              color: P.secondary
              font.family: root.fontMono
              font.pixelSize: 10
            }
            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: root.hostLabel(parent.parent.host)
              color: parent.parent.selected ? P.text : P.secondary
              font.family: P.sans
              font.pixelSize: 11
              font.weight: parent.parent.selected ? Font.Medium : Font.Normal
            }
            Text {
              textFormat: Text.PlainText
              visible: parent.parent.host.remoteNet === true
                && String(parent.parent.host.network || "") !== ""
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: String(parent.parent.host.network || "")
              color: P.blue
              font.family: P.sans
              font.pixelSize: 9
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: mapHover.hoverIp = parent.ip
            onExited: if (mapHover.hoverIp === parent.ip) mapHover.hoverIp = ""
            onClicked: root.hostSelected(parent.ip)
          }
        }
      }

      QtObject {
        id: mapHover
        property string hoverIp: ""
        onHoverIpChanged: linksCanvas.requestPaint()
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: root.mapHosts.length === 0
        text: root.scanFailed
          ? "The network scan did not complete."
          : (root.scanning ? "Listening for hosts…" : "Nothing on the map yet.")
        color: P.muted
        font.family: P.sans
        font.pixelSize: 13
      }
    }

    // Condensed devices panel under the map (mirrors the reference layout).
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: parent.height - mapArea.height - 10
      color: P.surface
      radius: P.radius
      border.width: 1
      border.color: P.border

      DeviceTable {
        anchors.fill: parent
        anchors.margins: 14
        fontMono: root.fontMono
        hosts: root.hosts
        title: "Devices on Your Network"
        compact: true
        selfName: root.selfName
        selectedIp: root.selectedIp
        onHostSelected: function(ip) { root.hostSelected(ip) }
      }
    }
  }

  // List mode: device cards.
  Flickable {
    visible: root.mode === "list"
    anchors.fill: parent
    contentWidth: width
    contentHeight: cardFlow.childrenRect.height + 32
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Flow {
      id: cardFlow
      x: 20
      y: 16
      width: parent.width - 40
      spacing: 12

      Repeater {
        model: root.mapHosts

        Rectangle {
          required property var modelData
          readonly property var host: modelData
          readonly property string ip: String(host.ip || "")
          width: 168
          height: 118
          radius: P.radius
          color: root.selectedIp === ip ? P.raised
            : (cardHover.containsMouse ? P.hover : P.surface)
          border.width: 1
          border.color: root.selectedIp === ip ? P.blue : P.border

          Column {
            anchors.centerIn: parent
            spacing: 5
            DeviceIcon {
              anchors.horizontalCenter: parent.horizontalCenter
              type: parent.parent.host.type || "unknown"
              ink: (parent.parent.host.ports || []).length > 0 ? P.accent : P.secondary
              glyphSize: 30
              fontFamily: root.fontMono
            }
            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: parent.parent.ip
              color: P.secondary
              font.family: root.fontMono
              font.pixelSize: 10
            }
            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              width: 148
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: {
                var label = root.hostLabel(parent.parent.host)
                return label !== "" ? label : "Unknown device"
              }
              color: P.text
              font.family: P.sans
              font.pixelSize: 12
            }
            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              width: 148
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: {
                var base = (parent.parent.host.ports || []).length + " open"
                var net = String(parent.parent.host.network || "")
                if (parent.parent.host.remoteNet === true && net !== "")
                  return base + " · " + net
                return base
              }
              color: P.muted
              font.family: P.sans
              font.pixelSize: 10
            }
          }

          MouseArea {
            id: cardHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.hostSelected(parent.ip)
          }
        }
      }
    }
  }

  // Table mode: the full-width device table without the map.
  DeviceTable {
    visible: root.mode === "table"
    anchors.fill: parent
    anchors.margins: 16
    fontMono: root.fontMono
    hosts: root.hosts
    title: ""
    compact: false
    selfName: root.selfName
    selectedIp: root.selectedIp
    onHostSelected: function(ip) { root.hostSelected(ip) }
  }
}
