import QtQuick
import "Palette.js" as P

// Settings page: scan profile, and honest notes about where things live.
Item {
  id: root
  property string fontMono: "monospace"
  property string profile: "standard"
  property var network: ({})
  signal profileSelected(string profile)

  Column {
    anchors.fill: parent
    anchors.margins: 22
    spacing: 16

    Text {
      textFormat: Text.PlainText
      text: "Settings"
      color: P.text
      font.family: P.sans
      font.pixelSize: 20
      font.weight: Font.DemiBold
    }

    Text {
      textFormat: Text.PlainText
      text: "Scan profile"
      color: P.text
      font.family: P.sans
      font.pixelSize: 13
      font.weight: Font.DemiBold
    }

    Row {
      spacing: 8
      Repeater {
        model: [
          { id: "standard", label: "Standard Scan", detail: "Common ports, fast" },
          { id: "quick", label: "Quick Scan", detail: "Discovery ports only, fastest" }
        ]
        Rectangle {
          required property var modelData
          readonly property bool selected: root.profile === modelData.id
          width: 220
          height: 52
          radius: P.radius
          color: selected ? P.accentSoft : P.surface
          border.width: 1
          border.color: selected ? P.accent : P.border

          Column {
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: parent.parent.selected ? P.accent : P.text
              font.family: P.sans
              font.pixelSize: 12
              font.weight: Font.DemiBold
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.detail
              color: P.secondary
              font.family: P.sans
              font.pixelSize: 10
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.profileSelected(modelData.id)
          }
        }
      }
    }

    Rectangle { width: parent.width - 44; height: 1; color: P.border }

    Text {
      textFormat: Text.PlainText
      text: "Rescan interval"
      color: P.text
      font.family: P.sans
      font.pixelSize: 13
      font.weight: Font.DemiBold
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width - 44
      text: "The automatic rescan clock is a plugin setting. Open the bar widget settings for Port Doctor (Omarchy plugin settings) to change it; the default is 5 minutes."
      color: P.secondary
      font.family: P.sans
      font.pixelSize: 12
      wrapMode: Text.WordWrap
    }

    Rectangle { width: parent.width - 44; height: 1; color: P.border }

    Text {
      textFormat: Text.PlainText
      text: "Privacy"
      color: P.text
      font.family: P.sans
      font.pixelSize: 13
      font.weight: Font.DemiBold
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width - 44
      text: "Everything Port Doctor knows stays in this window's memory: no files, no uploads, no history between restarts. Scans touch only private LAN addresses with bare TCP connects; hostnames come from DNS PTR and the devices' own mDNS announcements."
      color: P.secondary
      font.family: P.sans
      font.pixelSize: 12
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      text: "Port Doctor 0.1.0 · kb2uka.port-doctor"
      color: P.muted
      font.family: P.sans
      font.pixelSize: 10
    }
  }
}
