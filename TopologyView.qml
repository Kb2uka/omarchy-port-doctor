import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// Network map: the gateway at the center, one panel per network holding
// its devices in a tight grid, and a single link from the gateway to each
// panel instead of one spoke per device. Labels thin out as the network
// grows (full, name-only, hover-only) and the hovered or selected device
// is named by the inspector chip. The layout is computed in virtual
// coordinates and scaled to fit the view, so large networks stay neat.
// Map is one of three presentations (map, list, table) switched by the
// header control.
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
  property string hoverIp: ""
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

  // The group a host belongs to on the map: its controller-labelled
  // network, with plain names for the controller-less cases.
  function clusterName(host) {
    var nm = String(host.network || "")
    if (nm !== "") return nm
    return host.remoteNet === true ? "Routed" : "This network"
  }

  function hostByIp(ip) {
    for (var i = 0; i < mapHosts.length; i++)
      if (String(mapHosts[i].ip || "") === ip) return mapHosts[i]
    return null
  }

  // The inspector chip names the hovered (or selected) host, which is the
  // only label a dense map needs on demand.
  readonly property var inspectorHost: {
    var ip = root.hoverIp !== "" ? root.hoverIp : root.selectedIp
    return ip !== "" ? hostByIp(ip) : null
  }

  // ---------------------------------------------------------- geometry
  // Gateway at the origin; each network is a panel of grid cells placed on
  // a ring around it, sized by how many devices it holds. Straight down is
  // reserved for this machine, so even cluster counts take corner angles.
  // Everything is positioned in virtual coordinates first, then the whole
  // scene is scaled into the view.
  property var nodePlacements: []   // {host, x, y, size, labels, big}
  property var clusterPanels: []    // {name, routed, count, x, y, w, h}
  property var hubNode: null        // {x, y, r} in world coordinates
  property var selfLink: null       // {x, y} world center of this machine
  property int worldW: 10
  property int worldH: 10
  property real worldScale: 1

  function layout() {
    var w = mapArea.width, h = mapArea.height
    if (w < 100 || h < 100) return
    var self = null, gateway = null
    // Null-prototype map: a controller network named "toString" or
    // "constructor" must not resolve to an inherited member.
    var groups = [], byName = Object.create(null)
    var list = mapHosts
    for (var i = 0; i < list.length; i++) {
      var hst = list[i]
      if (hst.isSelf) { self = hst; continue }
      if (hst.isGateway) { gateway = hst; continue }
      var nm = clusterName(hst)
      var g = byName[nm]
      if (!g) {
        g = { name: nm, routed: hst.remoteNet === true, hosts: [] }
        byName[nm] = g
        groups.push(g)
      }
      // A panel reads as routed only when every member is reached through
      // the gateway; a mixed group keeps the local treatment.
      g.routed = g.routed && hst.remoteNet === true
      g.hosts.push(hst)
    }
    // Local network first, then biggest first, so positions survive
    // devices coming and going between scans.
    groups.sort(function(a, b) {
      if (a.routed !== b.routed) return a.routed ? 1 : -1
      if (a.hosts.length !== b.hosts.length) return b.hosts.length - a.hosts.length
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
    })

    var total = 0
    for (i = 0; i < groups.length; i++) total += groups[i].hosts.length
    // The busier the map, the less text each node carries.
    var tier
    if (total <= 10) tier = { node: 50, cellW: 108, cellH: 118, labels: 2 }
    else if (total <= 26) tier = { node: 44, cellW: 96, cellH: 100, labels: 1 }
    else tier = { node: 40, cellW: 72, cellH: 76, labels: 0 }

    var pad = 14, headerH = 38
    var maxHalf = 60
    for (i = 0; i < groups.length; i++) {
      var g = groups[i]
      var n = g.hosts.length
      var cols = n <= 2 ? n : Math.min(7, Math.max(3, Math.round(Math.sqrt(n * 1.5))))
      g.cols = cols
      g.w = cols * tier.cellW + pad * 2
      g.h = headerH + Math.ceil(n / cols) * tier.cellH + pad
      maxHalf = Math.max(maxHalf, g.w / 2, g.h / 2)
    }

    var k = groups.length
    var wide = w >= h * 1.25
    function placeGroups(ring) {
      var rx = ring * (wide ? 1.45 : 1.0)
      var ry = ring * (wide ? 0.72 : 1.0)
      for (var i = 0; i < k; i++) {
        var angle
        if (k === 1) angle = wide ? 0 : -Math.PI / 2
        else if (k === 2) angle = i === 0 ? 0 : Math.PI
        else if (k % 2 === 1) angle = -Math.PI / 2 + i * 2 * Math.PI / k
        else angle = -Math.PI / 2 + (i + 0.5) * 2 * Math.PI / k
        groups[i].vx = Math.cos(angle) * rx
        groups[i].vy = Math.sin(angle) * ry
      }
    }
    function overlapsSelf() {
      for (var i = 0; i < k; i++) {
        var g = groups[i]
        if (Math.abs(g.vx) < g.w / 2 + 70 && Math.abs(g.vy - 140) < g.h / 2 + 58)
          return true
      }
      return false
    }
    var ring = Math.max(300, maxHalf + 170)
    if (k > 1) {
      // Adjacent anchors must also clear the panels themselves. The
      // worst-case chord between two anchors on the ellipse is bounded by
      // 2 * min(rx, ry) * sin(pi / k), so size the ring from that floor.
      var minFactor = wide ? 0.72 : 1.0
      var need = 0
      for (i = 0; i < k; i++) {
        var gA = groups[i], gB = groups[(i + 1) % k]
        var extA = Math.sqrt(gA.w * gA.w + gA.h * gA.h) / 2
        var extB = Math.sqrt(gB.w * gB.w + gB.h * gB.h) / 2
        need = Math.max(need, extA + extB + 40)
      }
      ring = Math.max(ring, need / (2 * minFactor * Math.sin(Math.PI / k)))
    }
    placeGroups(ring)
    // Straight down is reserved for this machine; nudge the ring out until
    // no panel touches its box.
    if (self && gateway) {
      var bump = 0
      while (bump < 6 && overlapsSelf()) {
        ring *= 1.12
        placeGroups(ring)
        bump++
      }
    }

    var hub = gateway || self
    var hubVx = 0, hubVy = 0
    var selfVx = 0, selfVy = hub ? 140 : 0
    if (hub && hub === self && !gateway) { selfVx = 0; selfVy = 0 }

    // Bounding box over panels, hub, and this machine, with room for the
    // hub's two-line label.
    var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9
    function grow(vx, vy, halfW, halfH) {
      minX = Math.min(minX, vx - halfW); maxX = Math.max(maxX, vx + halfW)
      minY = Math.min(minY, vy - halfH); maxY = Math.max(maxY, vy + halfH)
    }
    for (i = 0; i < k; i++)
      grow(groups[i].vx, groups[i].vy, groups[i].w / 2, groups[i].h / 2)
    if (hub) grow(hubVx, hubVy + 14, 76, 66)
    if (self && hub !== self) grow(selfVx, selfVy + 12, 70, 58)
    if (minX > maxX) { minX = -80; maxX = 80; minY = -60; maxY = 60 }

    var offX = -minX + 12, offY = -minY + 12
    var placements = []
    var panels = []
    for (i = 0; i < k; i++) {
      var g2 = groups[i]
      var px = g2.vx - g2.w / 2 + offX
      var py = g2.vy - g2.h / 2 + offY
      panels.push({ name: g2.name, routed: g2.routed, count: g2.hosts.length,
                    x: px, y: py, w: g2.w, h: g2.h })
      for (var j = 0; j < g2.hosts.length; j++) {
        var col = j % g2.cols, row = Math.floor(j / g2.cols)
        placements.push({ host: g2.hosts[j],
                          x: px + pad + col * tier.cellW + tier.cellW / 2,
                          y: py + headerH + row * tier.cellH + tier.cellH / 2,
                          size: tier.node, labels: tier.labels, big: false,
                          cw: tier.cellW, ch: tier.cellH })
      }
    }
    if (gateway)
      placements.push({ host: gateway, x: hubVx + offX, y: hubVy + offY,
                        size: 64, labels: 2, big: true, cw: 148, ch: 110 })
    if (self)
      placements.push({ host: self, x: (hub === self ? hubVx : selfVx) + offX,
                        y: (hub === self ? hubVy : selfVy) + offY,
                        size: 56, labels: 2, big: true, cw: 140, ch: 100 })

    nodePlacements = placements
    clusterPanels = panels
    hubNode = hub ? { x: hubVx + offX, y: hubVy + offY,
                      r: gateway ? 34 : 30 } : null
    selfLink = (self && hub !== self) ? { x: selfVx + offX, y: selfVy + offY } : null
    worldW = Math.max(10, Math.round(maxX - minX + 24))
    worldH = Math.max(10, Math.round(maxY - minY + 24))
    wideState = wide ? 1 : 0
    fit()
    linksCanvas.requestPaint()
  }

  // A resize changes only the scale unless it flips the wide/narrow
  // arrangement, so dragging the window edge does not rebuild the grid.
  property int wideState: -1

  function fit() {
    var w = mapArea.width, h = mapArea.height
    if (w < 100 || h < 100) return
    worldScale = Math.min(1, (w - 16) / worldW, (h - 16) / worldH)
  }

  function sizeChanged() {
    var w = mapArea.width, h = mapArea.height
    if (w < 100 || h < 100) return
    var ws = w >= h * 1.25 ? 1 : 0
    if (wideState >= 0 && ws === wideState) fit()
    else layout()
  }

  onModeChanged: if (mode === "map") layout()
  onHostsChanged: {
    layout()
    // A hovered device that went offline or got filtered out must not keep
    // hoverIp: it would blank the inspector and mute the selection link.
    if (root.hoverIp !== "" && hostByIp(root.hoverIp) === null) root.hoverIp = ""
  }
  onSelectedIpChanged: linksCanvas.requestPaint()
  onHoverIpChanged: linksCanvas.requestPaint()

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
      onWidthChanged: root.sizeChanged()
      onHeightChanged: root.sizeChanged()
      Component.onCompleted: root.layout()

      Item {
        id: world
        width: root.worldW
        height: root.worldH
        anchors.centerIn: parent
        scale: root.worldScale

        Canvas {
          id: linksCanvas
          anchors.fill: parent
          onPaint: {
            var c = getContext("2d")
            c.reset()
            var hub = root.hubNode
            if (!hub) return
            var hotIp = root.hoverIp !== "" ? root.hoverIp : root.selectedIp
            var hotHost = hotIp !== "" ? root.hostByIp(hotIp) : null
            var hotNet = hotHost ? root.clusterName(hotHost) : ""
            var panels = root.clusterPanels
            for (var i = 0; i < panels.length; i++) {
              var p = panels[i]
              var pcx = p.x + p.w / 2, pcy = p.y + p.h / 2
              var dx = pcx - hub.x, dy = pcy - hub.y
              var len = Math.max(1, Math.sqrt(dx * dx + dy * dy))
              var tx = dx !== 0 ? (p.w / 2) / Math.abs(dx) : 1e9
              var ty = dy !== 0 ? (p.h / 2) / Math.abs(dy) : 1e9
              var t = Math.min(tx, ty, 1)
              var ex = pcx - dx * t, ey = pcy - dy * t
              var sx = hub.x + dx / len * hub.r, sy = hub.y + dy / len * hub.r
              var hot = hotNet !== "" && hotNet === p.name
              c.beginPath()
              c.moveTo(sx, sy)
              var mx = (sx + ex) / 2, my = (sy + ey) / 2
              c.quadraticCurveTo(mx - dy * 0.06, my + dx * 0.06, ex, ey)
              // A dashed link is a routed path: that network is reached
              // through the gateway, not by the local subnet directly.
              c.setLineDash(p.routed && !hot ? [5, 5] : [])
              c.strokeStyle = hot ? P.alpha(P.teal, 0.75)
                : (p.routed ? P.alpha(P.blue, 0.5) : P.alpha("#3c5268", 0.55))
              c.lineWidth = hot ? 1.6 : 1.2
              c.stroke()
            }
            c.setLineDash([])
            var sl = root.selfLink
            if (sl) {
              var sdx = sl.x - hub.x, sdy = sl.y - hub.y
              var slen = Math.max(1, Math.sqrt(sdx * sdx + sdy * sdy))
              c.beginPath()
              c.moveTo(hub.x + sdx / slen * hub.r, hub.y + sdy / slen * hub.r)
              // Bow right so the line clears the hub's centered label.
              c.quadraticCurveTo((hub.x + sl.x) / 2 + 36, (hub.y + sl.y) / 2,
                                 sl.x, sl.y - 30)
              c.strokeStyle = P.alpha(P.accent, 0.45)
              c.lineWidth = 1.2
              c.stroke()
            }
          }
        }

        Repeater {
          model: root.clusterPanels

          Rectangle {
            required property var modelData
            x: modelData.x
            y: modelData.y
            width: modelData.w
            height: modelData.h
            radius: P.radius
            color: P.surface
            border.width: 1
            border.color: modelData.routed ? P.alpha(P.blue, 0.55) : P.border

            Text {
              textFormat: Text.PlainText
              x: 14
              y: 10
              width: parent.width - 28
              elide: Text.ElideRight
              text: modelData.name + " · " + modelData.count
              color: modelData.routed ? P.blue : P.secondary
              font.family: P.sans
              font.pixelSize: 12
              font.weight: Font.Medium
            }
          }
        }

        Repeater {
          model: root.nodePlacements

          Item {
            required property var modelData
            readonly property var host: modelData.host
            readonly property string ip: String(host.ip || "")
            readonly property bool selected: root.selectedIp === ip
            readonly property bool hovered: root.hoverIp === ip
            readonly property int portCount: (host.ports || []).length
            readonly property int nodeSize: modelData.size
            readonly property int cellW: modelData.cw
            readonly property int cellH: modelData.ch

            x: modelData.x - cellW / 2
            y: modelData.y - cellH / 2
            width: cellW
            height: cellH

            Rectangle {
              width: parent.nodeSize
              height: parent.nodeSize
              anchors.horizontalCenter: parent.horizontalCenter
              y: modelData.labels > 0 ? 0 : (parent.cellH - parent.nodeSize) / 2
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
              x: parent.width / 2 + parent.nodeSize / 2 - 12
              y: (modelData.labels > 0 ? 0 : (parent.cellH - parent.nodeSize) / 2) + 2
            }

            Column {
              visible: modelData.labels > 0
              anchors.top: parent.top
              anchors.topMargin: parent.nodeSize + 5
              width: parent.cellW - 6
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: 1

              Text {
                textFormat: Text.PlainText
                // Name-only tier (labels === 1) drops the IP line.
                visible: modelData.labels === 2
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
                font.pixelSize: modelData.big ? 12 : 11
                font.weight: parent.parent.selected || modelData.big ? Font.Medium : Font.Normal
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.hoverIp = parent.ip
              onExited: if (root.hoverIp === parent.ip) root.hoverIp = ""
              onClicked: root.hostSelected(parent.ip)
            }
          }
        }
      }

      // The inspector chip: names the hovered or selected device without
      // printing a label under every node on a dense map.
      Rectangle {
        id: inspector
        visible: root.inspectorHost !== null
        x: 12
        y: 12
        width: 250
        height: 68
        radius: P.radius
        color: P.raised
        border.width: 1
        border.color: P.borderStrong

        readonly property var host: root.inspectorHost

        DeviceIcon {
          id: inspectorIcon
          x: 14
          anchors.verticalCenter: parent.verticalCenter
          type: inspector.host ? (inspector.host.type || "unknown") : "unknown"
          ink: inspector.host && (inspector.host.ports || []).length > 0 ? P.accent : P.secondary
          glyphSize: 26
          fontFamily: root.fontMono
        }

        Column {
          x: 52
          width: parent.width - 64
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2

          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: inspector.host ? root.hostLabel(inspector.host) : ""
            color: P.text
            font.family: P.sans
            font.pixelSize: 13
            font.weight: Font.Medium
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: inspector.host ? String(inspector.host.ip || "") : ""
            color: P.secondary
            font.family: root.fontMono
            font.pixelSize: 11
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: {
              if (!inspector.host) return ""
              var bits = []
              var net = root.clusterName(inspector.host)
              if (net !== "") bits.push(net)
              var vendor = String(inspector.host.vendor || "")
              if (vendor !== "") bits.push(vendor)
              bits.push((inspector.host.ports || []).length + " open ports")
              var lat = inspector.host.latencyMs
              if (lat !== null && lat !== undefined) bits.push(lat + " ms")
              return bits.join(" · ")
            }
            color: P.muted
            font.family: P.sans
            font.pixelSize: 10
          }
        }
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
