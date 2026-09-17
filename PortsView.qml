import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// Every open port found, one row per host:port, sorted by port.
Item {
  id: root
  property string fontMono: "monospace"
  property var hosts: []

  readonly property var rows: {
    var out = []
    for (var i = 0; i < hosts.length; i++) {
      var h = hosts[i]
      var ports = h.ports || []
      for (var j = 0; j < ports.length; j++) {
        out.push({ port: ports[j].port, service: ports[j].service,
                   klass: ports[j].class, proto: ports[j].proto,
                   ip: h.ip, name: h.hostname || h.vendor || "",
                   online: h.online })
      }
    }
    out.sort(function(a, b) { return a.port - b.port })
    return out
  }

  Column {
    anchors.fill: parent
    anchors.margins: 18
    spacing: 10

    Row {
      spacing: 10
      Text {
        textFormat: Text.PlainText
        text: "Open Ports"
        color: P.text
        font.family: P.sans
        font.pixelSize: 15
        font.weight: Font.DemiBold
      }
      Text {
        textFormat: Text.PlainText
        text: root.rows.length + " listening services found"
        color: P.muted
        font.family: P.sans
        font.pixelSize: 11
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Rectangle {
      width: parent.width
      height: 34
      color: P.alpha(P.border, 0.18)
      radius: 4
      Row {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        Repeater {
          model: [["PORT", 0.10], ["SERVICE", 0.18], ["CLASS", 0.14],
                  ["HOST", 0.34], ["DEVICE", 0.24]]
          Text {
            required property var modelData
            textFormat: Text.PlainText
            width: parent.width * modelData[1]
            anchors.verticalCenter: parent.verticalCenter
            text: modelData[0]
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
      width: parent.width
      height: parent.height - 54 - parent.spacing * 2
      contentWidth: width
      contentHeight: portColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: portColumn
        width: parent.width

        Repeater {
          model: root.rows

          Rectangle {
            required property var modelData
            width: portColumn.width
            height: 36
            color: rowHover.containsMouse ? P.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 80 } }

            Row {
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 10

              Item {
                width: parent.width * 0.10
                height: parent.height
                PortBadge {
                  port: modelData.port
                  service: modelData.service
                  klass: modelData.klass
                  fontFamily: P.sans
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.18
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.service)
                color: P.classColor(modelData.klass)
                font.family: P.sans
                font.pixelSize: 12
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.14
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.klass)
                color: P.secondary
                font.family: P.sans
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.34
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.ip)
                color: P.text
                font.family: root.fontMono
                font.pixelSize: 12
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.24
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.name).replace(/\.local$/, "")
                color: P.secondary
                font.family: P.sans
                font.pixelSize: 11
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.rows.length === 0
          width: parent.width
          topPadding: 24
          horizontalAlignment: Text.AlignHCenter
          text: "No open ports found yet. Run a scan."
          color: P.muted
          font.family: P.sans
          font.pixelSize: 12
        }
      }
    }
  }
}
