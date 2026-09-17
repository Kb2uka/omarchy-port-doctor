import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// This Mac: listening sockets and live connections of the machine itself.
Item {
  id: root
  property string fontMono: "monospace"
  property string hostname: ""
  property var listeners: []
  property var connections: []
  property string scannedAt: ""
  property bool failed: false
  signal refreshRequested

  readonly property int lanPeers: {
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
    var order = [["lan", P.teal], ["private", P.blue],
                 ["internet", P.secondary], ["loopback", P.muted],
                 ["unknown", P.muted]]
    var out = []
    for (var j = 0; j < order.length; j++)
      if (counts[order[j][0]])
        out.push({ kind: order[j][0], count: counts[order[j][0]],
                   color: order[j][1],
                   fraction: counts[order[j][0]] / Math.max(1, total) })
    return out
  }

  Column {
    anchors.fill: parent
    anchors.margins: 18
    spacing: 14

    Row {
      id: headerRow
      spacing: 10
      Text {
        textFormat: Text.PlainText
        text: root.hostname !== "" ? root.hostname : "This Mac"
        color: P.text
        font.family: P.sans
        font.pixelSize: 15
        font.weight: Font.DemiBold
      }
      Text {
        textFormat: Text.PlainText
        text: root.failed ? "socket read failed" : "live · " + P.ageText(root.scannedAt)
        color: root.failed ? P.red : P.muted
        font.family: P.sans
        font.pixelSize: 11
        anchors.verticalCenter: parent.verticalCenter
      }
      Item { width: 4; height: 1 }
      Rectangle {
        width: 26
        height: 26
        radius: P.radius
        color: refreshHover.containsMouse ? P.hover : "transparent"
        border.width: 1
        border.color: P.border
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "\u{F0450}"
          color: P.secondary
          font.family: root.fontMono
          font.pixelSize: 12
        }
        MouseArea {
          id: refreshHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.refreshRequested()
        }
      }
    }

    // Stat tiles
    Row {
      id: tilesRow
      width: parent.width
      spacing: 10

      Repeater {
        model: [
          { label: "LISTENING", value: root.listeners.length, tint: P.accent },
          { label: "TALKING", value: root.connections.length, tint: P.text },
          { label: "LAN PEERS", value: root.lanPeers, tint: P.teal }
        ]

        Rectangle {
          required property var modelData
          width: (parent.width - 20) / 3
          height: 64
          radius: P.radius
          color: P.surface
          border.width: 1
          border.color: P.border

          Column {
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
              textFormat: Text.PlainText
              text: String(modelData.value)
              color: modelData.tint
              font.family: P.sans
              font.pixelSize: 22
              font.weight: Font.DemiBold
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: P.muted
              font.family: P.sans
              font.pixelSize: 10
              font.bold: true
              font.letterSpacing: 1.1
            }
          }
        }
      }
    }

    // Traffic mix bar
    Column {
      id: mixBlock
      visible: root.kindBreakdown.length > 0
      width: parent.width
      spacing: 6

      Rectangle {
        width: parent.width
        height: 6
        radius: 3
        color: P.alpha(P.border, 0.4)
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
        spacing: 14
        Repeater {
          model: root.kindBreakdown
          Row {
            required property var modelData
            spacing: 6
            Rectangle {
              width: 7
              height: 7
              radius: 2
              color: modelData.color
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.count + " " + modelData.kind
              color: P.secondary
              font.family: P.sans
              font.pixelSize: 10
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }

    // Two tables side by side, filling what the header, tiles, and mix
    // bar leave (the mix bar is conditional, so it is measured).
    Row {
      width: parent.width
      height: parent.height - headerRow.implicitHeight - tilesRow.implicitHeight
        - (mixBlock.visible ? mixBlock.implicitHeight + 3 * 14 : 2 * 14)
      spacing: 14

      // Listeners
      Rectangle {
        width: (parent.width - 14) / 2
        height: parent.height
        radius: P.radius
        color: P.surface
        border.width: 1
        border.color: P.border

        Column {
          anchors.fill: parent
          anchors.margins: 12
          spacing: 8

          Text {
            textFormat: Text.PlainText
            text: "LISTENING · " + root.listeners.length
            color: P.muted
            font.family: P.sans
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.1
          }

          Flickable {
            width: parent.width
            height: parent.height - 26
            contentWidth: width
            contentHeight: listenColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: listenColumn
              width: parent.width
              spacing: 2

              Repeater {
                model: root.listeners

                Rectangle {
                  id: listenRowCard
                  required property var modelData
                  readonly property bool lanOpen: String(modelData.scope) === "all interfaces"
                  width: listenColumn.width
                  height: 34
                  radius: 4
                  color: listenHover.containsMouse ? P.hover : "transparent"

                  Row {
                    x: 8
                    width: parent.width - 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Text {
                      textFormat: Text.PlainText
                      width: 52
                      text: String(modelData.port)
                      color: P.text
                      font.family: root.fontMono
                      font.pixelSize: 12
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: 80
                      text: String(modelData.service)
                      color: P.classColor(modelData["class"])
                      font.family: P.sans
                      font.pixelSize: 11
                      elide: Text.ElideRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width - 52 - 80 - 120 - 30
                      text: String(modelData.process || "system")
                      color: P.secondary
                      font.family: P.sans
                      font.pixelSize: 10
                      elide: Text.ElideRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: listenRowCard.lanOpen ? "LAN" : "local"
                      color: listenRowCard.lanOpen ? P.accent : P.muted
                      font.family: P.sans
                      font.pixelSize: 10
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    id: listenHover
                    anchors.fill: parent
                    hoverEnabled: true
                  }
                }
              }
            }
          }
        }
      }

      // Connections
      Rectangle {
        width: (parent.width - 14) / 2
        height: parent.height
        radius: P.radius
        color: P.surface
        border.width: 1
        border.color: P.border

        Column {
          anchors.fill: parent
          anchors.margins: 12
          spacing: 8

          Text {
            textFormat: Text.PlainText
            text: "TALKING TO · " + root.connections.length
            color: P.muted
            font.family: P.sans
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.1
          }

          Flickable {
            width: parent.width
            height: parent.height - 26
            contentWidth: width
            contentHeight: connColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: connColumn
              width: parent.width
              spacing: 2

              Repeater {
                model: root.connections

                Rectangle {
                  id: connRowCard
                  required property var modelData
                  readonly property color kindColor: {
                    switch (String(modelData.remoteKind)) {
                      case "lan": return P.teal
                      case "private": return P.blue
                      case "internet": return P.secondary
                      default: return P.muted
                    }
                  }
                  width: connColumn.width
                  height: 34
                  radius: 4
                  color: connHover.containsMouse ? P.hover : "transparent"

                  Row {
                    x: 8
                    width: parent.width - 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Rectangle {
                      width: 7
                      height: 7
                      radius: 2
                      color: connRowCard.kindColor
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: 92
                      text: String(connRowCard.modelData.process || "system")
                      color: P.text
                      font.family: P.sans
                      font.pixelSize: 10
                      elide: Text.ElideRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width - 92 - 70 - 30 - 30
                      text: {
                        var c = connRowCard.modelData
                        var nm = String(c.remoteName || "")
                        return (nm !== "" ? nm.replace(/\.local$/, "") : String(c.remoteIp))
                          + ":" + c.remotePort
                      }
                      color: connRowCard.kindColor
                      font.family: root.fontMono
                      font.pixelSize: 11
                      elide: Text.ElideRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: 30
                      text: String(connRowCard.modelData.state).slice(0, 4)
                      color: P.muted
                      font.family: P.sans
                      font.pixelSize: 10
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: String(connRowCard.modelData.remoteKind).toUpperCase()
                      color: connRowCard.kindColor
                      font.family: P.sans
                      font.pixelSize: 10
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    id: connHover
                    anchors.fill: parent
                    hoverEnabled: true
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
