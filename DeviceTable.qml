import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// The devices table with filter chips and expandable rows. Shared by the
// topology page (compact) and the Devices page (full height).
Item {
  id: root
  property string fontMono: "monospace"
  property var hosts: []
  property string title: "Devices on Your Network"
  property bool compact: false
  property string selectedIp: ""
  property string expandedIp: ""
  property string selfName: ""
  signal hostSelected(string ip)

  property string filter: "all"
  property string networkFilter: ""

  // A stale network selection must not strand the table empty: when a
  // rescan loses that network, fall back to All Networks.
  onNetworksPresentChanged: {
    if (root.networkFilter !== ""
        && root.networksPresent.indexOf(root.networkFilter) < 0)
      root.networkFilter = ""
  }

  readonly property int onlineCount: {
    var n = 0
    for (var i = 0; i < hosts.length; i++) if (hosts[i].online) n++
    return n
  }
  readonly property int portsOnlyCount: {
    var n = 0
    for (var i = 0; i < hosts.length; i++)
      if (hosts[i].online && (hosts[i].ports || []).length > 0) n++
    return n
  }

  // Controller-labelled networks present in the data (empty when the
  // scan only knows its own subnet).
  readonly property var networksPresent: {
    var seen = {}
    var out = []
    for (var i = 0; i < hosts.length; i++) {
      var name = String(hosts[i].network || "")
      if (name !== "" && !seen[name]) {
        seen[name] = true
        out.push(name)
      }
    }
    return out.sort()
  }

  readonly property var filteredHosts: {
    var out = []
    for (var i = 0; i < hosts.length; i++) {
      var h = hosts[i]
      if (filter === "online" && !h.online) continue
      if (filter === "offline" && h.online) continue
      if (filter === "ports" && ((h.ports || []).length === 0 || !h.online)) continue
      if (networkFilter !== "" && String(h.network || "") !== networkFilter) continue
      out.push(h)
    }
    return out
  }

  readonly property var columns: [
    { label: "IP ADDRESS", w: 0.16 },
    { label: "DEVICE NAME", w: 0.22 },
    { label: "VENDOR", w: 0.14 },
    { label: "OPEN PORTS", w: 0.24 },
    { label: "LAST SEEN", w: 0.11 },
    { label: "STATUS", w: 0.13 }
  ]

  function displayName(host) {
    if (host.isSelf) return root.selfName !== "" ? root.selfName : "This machine"
    var nm = String(host.hostname || "")
    if (nm !== "") return nm.replace(/\.local$/, "")
    if (host.isGateway) return "Gateway"
    return ""
  }

  Row {
    id: titleRow
    visible: root.title !== ""
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 26
    spacing: 10

    Text {
      textFormat: Text.PlainText
      text: root.title
      color: P.text
      font.family: P.sans
      font.pixelSize: 15
      font.weight: Font.DemiBold
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      textFormat: Text.PlainText
      text: root.hosts.length + " devices"
      color: P.muted
      font.family: P.sans
      font.pixelSize: 11
      anchors.verticalCenter: parent.verticalCenter
    }
    Item { width: 4; height: 1 }

    Row {
      spacing: 6
      anchors.verticalCenter: parent.verticalCenter

      Repeater {
        model: [
          { id: "all", label: "All", count: root.hosts.length },
          { id: "online", label: "Online", count: root.onlineCount },
          { id: "offline", label: "Offline", count: root.hosts.length - root.onlineCount },
          { id: "ports", label: "With Open Ports", count: root.portsOnlyCount }
        ]

        Rectangle {
          required property var modelData
          readonly property bool selected: root.filter === modelData.id
          implicitWidth: chipText.implicitWidth + 18
          implicitHeight: 24
          radius: 12
          color: selected ? P.accentSoft
            : (chipHover.containsMouse ? P.hover : "transparent")
          border.width: 1
          border.color: selected ? P.accent : P.border

          Text {
            id: chipText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: modelData.label + "  " + modelData.count
            color: parent.selected ? P.accent : P.secondary
            font.family: P.sans
            font.pixelSize: 10
            font.bold: parent.selected
          }

          MouseArea {
            id: chipHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.filter = modelData.id
          }
        }
      }
    }
  }

  // Network filter chips, shown only when the controller brought more
  // than one network into view. Flow wraps chips instead of overflowing
  // narrow windows.
  Flow {
    id: networkRow
    visible: root.networksPresent.length > 1
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: titleRow.visible ? titleRow.bottom : parent.top
    anchors.topMargin: titleRow.visible ? 8 : 0
    height: visible ? implicitHeight : 0
    spacing: 6

    Repeater {
      model: {
        var chips = [{ id: "", label: "All Networks" }]
        for (var i = 0; i < root.networksPresent.length; i++)
          chips.push({ id: root.networksPresent[i], label: root.networksPresent[i] })
        return chips
      }

      Rectangle {
        required property var modelData
        readonly property bool selected: root.networkFilter === modelData.id
        implicitWidth: netChipText.implicitWidth + 18
        implicitHeight: 24
        radius: 12
        color: selected ? P.alpha(P.blue, 0.16)
          : (netChipHover.containsMouse ? P.hover : "transparent")
        border.width: 1
        border.color: selected ? P.blue : P.border

        Text {
          id: netChipText
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: modelData.label
          color: parent.selected ? P.blue : P.secondary
          font.family: P.sans
          font.pixelSize: 10
          font.bold: parent.selected
        }

        MouseArea {
          id: netChipHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.networkFilter = modelData.id
        }
      }
    }
  }

  // Header
  Rectangle {
    id: headerBar
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: networkRow.visible ? networkRow.bottom
      : (titleRow.visible ? titleRow.bottom : parent.top)
    anchors.topMargin: (networkRow.visible || titleRow.visible) ? 10 : 0
    height: 34
    color: P.alpha(P.border, 0.18)
    radius: 4

    Row {
      anchors.fill: parent
      anchors.leftMargin: 10
      anchors.rightMargin: 10

      Repeater {
        model: root.columns

        Text {
          required property var modelData
          textFormat: Text.PlainText
          width: parent.width * modelData.w
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          color: P.muted
          font.family: P.sans
          font.pixelSize: 10
          font.bold: true
          font.letterSpacing: 0.8
          elide: Text.ElideRight
        }
      }
    }
  }

  Flickable {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: headerBar.bottom
    anchors.topMargin: 4
    anchors.bottom: parent.bottom
    contentWidth: width
    contentHeight: contentColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: contentColumn
      width: parent.width

      Repeater {
        model: root.filteredHosts

        Column {
          id: rowDelegate
          required property var modelData
          readonly property var host: modelData
          readonly property string ip: String(host.ip || "")
          readonly property bool selected: root.selectedIp === ip
          readonly property bool expanded: root.expandedIp === ip

          width: contentColumn.width

          Rectangle {
            width: rowDelegate.width
            height: 42
            color: rowDelegate.selected ? P.raised
              : (rowHover.containsMouse ? P.hover : "transparent")
            opacity: rowDelegate.host.online ? 1.0 : 0.55
            Behavior on color { ColorAnimation { duration: 80 } }

            Row {
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 10

              Item {
                width: parent.width * 0.16
                height: parent.height
                Row {
                  spacing: 8
                  anchors.verticalCenter: parent.verticalCenter
                  DeviceIcon {
                    type: rowDelegate.host.type || "unknown"
                    ink: P.secondary
                    glyphSize: 14
                    fontFamily: root.fontMono
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: rowDelegate.ip
                    color: P.text
                    font.family: root.fontMono
                    font.pixelSize: 12
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.22
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: root.displayName(rowDelegate.host)
                color: P.text
                font.family: P.sans
                font.pixelSize: 12
                font.weight: Font.Medium
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.14
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: {
                  var v = String(rowDelegate.host.vendor || "")
                  if (v === "" && rowDelegate.host.macPrivate) return "Private"
                  return v
                }
                color: P.secondary
                font.family: P.sans
                font.pixelSize: 12
              }

              Item {
                width: parent.width * 0.24
                height: parent.height
                Row {
                  spacing: 5
                  anchors.verticalCenter: parent.verticalCenter
                  Repeater {
                    model: (rowDelegate.host.ports || []).slice(0, 4)
                    PortBadge {
                      required property var modelData
                      port: modelData.port
                      service: modelData.service
                      klass: modelData.class
                      fontFamily: P.sans
                    }
                  }
                  Text {
                    visible: (rowDelegate.host.ports || []).length > 4
                    textFormat: Text.PlainText
                    text: "+" + ((rowDelegate.host.ports || []).length - 4)
                    color: P.muted
                    font.family: P.sans
                    font.pixelSize: 10
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    visible: (rowDelegate.host.ports || []).length === 0
                    textFormat: Text.PlainText
                    text: "—"
                    color: P.muted
                    font.family: P.sans
                    font.pixelSize: 11
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.11
                anchors.verticalCenter: parent.verticalCenter
                text: P.ageText(rowDelegate.host.lastSeen || "")
                color: P.secondary
                font.family: P.sans
                font.pixelSize: 11
                elide: Text.ElideRight
              }

              Row {
                width: parent.width * 0.13
                height: parent.height
                spacing: 7
                StatusDot {
                  online: !!rowDelegate.host.online
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  textFormat: Text.PlainText
                  text: rowDelegate.host.online ? "Online" : "Offline"
                  color: rowDelegate.host.online ? P.green : P.muted
                  font.family: P.sans
                  font.pixelSize: 11
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.expandedIp = rowDelegate.expanded ? "" : rowDelegate.ip
                root.hostSelected(rowDelegate.ip)
              }
            }
          }

          // Expanded detail strip
          Rectangle {
            visible: rowDelegate.expanded
            width: rowDelegate.width
            height: rowDelegate.expanded ? detailColumn.implicitHeight + 16 : 0
            color: P.alpha(P.border, 0.10)

            Column {
              id: detailColumn
              x: 34
              y: 8
              width: parent.width - 44
              spacing: 4

              Text {
                textFormat: Text.PlainText
                text: {
                  var h = rowDelegate.host
                  var parts = []
                  if (String(h.mac || "") !== "") parts.push(String(h.mac))
                  parts.push("type " + String(h.type || "unknown"))
                  if (h.latencyMs !== null && h.latencyMs !== undefined)
                    parts.push(String(h.latencyMs) + " ms")
                  if (String(h.network || "") !== "")
                    parts.push("network " + String(h.network))
                  parts.push(h.via === "unifi" ? "reported by controller"
                    : h.via === "neigh" ? "seen in neighbor table"
                    : h.via === "self" ? "this machine"
                    : h.via === "route" ? "the default gateway"
                    : "answered probes")
                  return parts.join("  ·  ")
                }
                color: P.secondary
                font.family: root.fontMono
                font.pixelSize: 10
              }

              Flow {
                width: parent.width
                spacing: 5
                Repeater {
                  model: rowDelegate.host.ports || []
                  PortBadge {
                    required property var modelData
                    port: modelData.port
                    service: modelData.service
                    klass: modelData.class
                    fontFamily: P.sans
                  }
                }
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.filteredHosts.length === 0
        width: parent.width
        topPadding: 24
        horizontalAlignment: Text.AlignHCenter
        text: "No devices match this view."
        color: P.muted
        font.family: P.sans
        font.pixelSize: 12
      }
    }
  }
}
