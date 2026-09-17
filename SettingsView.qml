import QtQuick
import "Palette.js" as P

// Settings page: scan profile, controller status, and honest notes about
// where things live.
Item {
  id: root
  property string fontMono: "monospace"
  property string profile: "standard"
  property var network: ({})
  property var controller: ({})
  signal profileSelected(string profile)

  function controllerError() {
    var e = root.controller.error
    return (e === null || e === undefined) ? "" : String(e)
  }

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
      text: "UniFi controller · whole-network view"
      color: P.text
      font.family: P.sans
      font.pixelSize: 13
      font.weight: Font.DemiBold
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width - 44
      text: {
        if (root.controller.configured === true) {
          if (root.controllerError() !== "")
            return "Configured at " + String(root.controller.host || "?")
              + " but the last read failed: " + root.controllerError()
          return "Connected to " + String(root.controller.host || "?")
            + (String(root.controller.site || "") !== ""
               ? " · site " + String(root.controller.site) : "")
            + " · " + Number(root.controller.clients || 0) + " clients reported"
        }
        if (root.controllerError() !== "")
          return "A config file was found but ignored: " + root.controllerError()
        return "Not configured, so the map shows only this subnet. To see every network your UniFi controller manages, create ~/.config/port-doctor/unifi.env with two lines: UNIFI_HOST=<its private IP> and UNIFI_API_KEY=<a read-only local API key>. Port Doctor only ever reads that file, queries nothing but the controller, and probes only private addresses."
      }
      color: root.controllerError() !== "" ? P.red : P.secondary
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
      text: "Everything Port Doctor learns stays in this window's memory: no files written, no uploads, no history between restarts. Scans touch only private LAN addresses with bare TCP connects; hostnames come from DNS PTR and the devices' own mDNS announcements. If you configure a UniFi controller, the only added traffic is read-only HTTPS queries to that controller, and your API key is sent to its private address only."
      color: P.secondary
      font.family: P.sans
      font.pixelSize: 12
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      text: "Port Doctor 0.2.0 · kb2uka.port-doctor"
      color: P.muted
      font.family: P.sans
      font.pixelSize: 10
    }
  }
}
