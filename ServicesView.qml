import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// Services aggregated across hosts: who offers ssh, https, dns, and so on.
Item {
  id: root
  property string fontMono: "monospace"
  property var hosts: []

  readonly property var groups: {
    var byService = {}
    var order = []
    for (var i = 0; i < hosts.length; i++) {
      var h = hosts[i]
      var ports = h.ports || []
      for (var j = 0; j < ports.length; j++) {
        var p = ports[j]
        var key = String(p.service)
        if (!byService[key]) {
          byService[key] = { service: key, klass: p["class"], hosts: [], ports: [] }
          order.push(key)
        }
        var g = byService[key]
        if (g.hosts.indexOf(h.ip) < 0) g.hosts.push(h.ip)
        if (g.ports.indexOf(p.port) < 0) g.ports.push(p.port)
      }
    }
    order.sort(function(a, b) {
      return byService[b].hosts.length - byService[a].hosts.length
          || a.localeCompare(b)
    })
    return order.map(function(key) { return byService[key] })
  }

  Column {
    anchors.fill: parent
    anchors.margins: 18
    spacing: 10

    Row {
      spacing: 10
      Text {
        textFormat: Text.PlainText
        text: "Services"
        color: P.text
        font.family: P.sans
        font.pixelSize: 15
        font.weight: Font.DemiBold
      }
      Text {
        textFormat: Text.PlainText
        text: root.groups.length + " distinct services on the network"
        color: P.muted
        font.family: P.sans
        font.pixelSize: 11
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Flickable {
      width: parent.width
      height: parent.height - 32
      contentWidth: width
      contentHeight: serviceFlow.childrenRect.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Flow {
        id: serviceFlow
        width: parent.width
        spacing: 10

        Repeater {
          model: root.groups

          Rectangle {
            id: svcCard
            required property var modelData
            readonly property var group: modelData
            width: Math.min(330, Math.max(240, serviceFlow.width / 3 - 10))
            height: 92
            radius: P.radius
            color: svcHover.containsMouse ? P.hover : P.surface
            border.width: 1
            border.color: P.border
            Behavior on color { ColorAnimation { duration: 80 } }

            Column {
              x: 12
              y: 10
              width: parent.width - 24
              spacing: 5

              Row {
                spacing: 8
                Rectangle {
                  width: 8
                  height: 8
                  radius: 2
                  color: P.classColor(svcCard.group.klass)
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  textFormat: Text.PlainText
                  text: svcCard.group.service
                  color: P.text
                  font.family: P.sans
                  font.pixelSize: 13
                  font.weight: Font.DemiBold
                }
                Text {
                  textFormat: Text.PlainText
                  text: svcCard.group.klass
                  color: P.muted
                  font.family: P.sans
                  font.pixelSize: 10
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                textFormat: Text.PlainText
                text: svcCard.group.hosts.length + " host"
                  + (svcCard.group.hosts.length === 1 ? "" : "s")
                  + " · port" + (svcCard.group.ports.length === 1 ? " " : "s ")
                  + svcCard.group.ports.join(", ")
                color: P.secondary
                font.family: P.sans
                font.pixelSize: 10
              }

              Flow {
                width: parent.width
                spacing: 4
                Repeater {
                  model: svcCard.group.hosts.slice(0, 5)
                  Text {
                    required property var modelData
                    textFormat: Text.PlainText
                    text: String(modelData)
                    color: P.secondary
                    font.family: root.fontMono
                    font.pixelSize: 10
                  }
                }
                Text {
                  visible: svcCard.group.hosts.length > 5
                  textFormat: Text.PlainText
                  text: "+" + (svcCard.group.hosts.length - 5)
                  color: P.muted
                  font.family: root.fontMono
                  font.pixelSize: 10
                }
              }
            }

            MouseArea {
              id: svcHover
              anchors.fill: parent
              hoverEnabled: true
            }
          }
        }
      }
    }
  }
}
