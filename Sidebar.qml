import QtQuick
import "Palette.js" as P

// Left navigation rail: brand, sections, scan controls. Orange is reserved
// for the selected section's edge and the primary Scan Network action.
Rectangle {
  id: root
  color: P.sidebar

  property string fontMono: "monospace"
  property string page: "topology"
  property string profile: "standard"
  property string lastScanAt: ""
  property bool scanning: false
  property bool compact: false
  property bool rail: false
  property string selfName: ""

  signal navigate(string page)
  signal profileSelected(string profile)
  signal scanRequested

  readonly property var navModel: [
    { page: "topology", label: "Network Map", glyph: "\u{F0317}" },
    { page: "devices", label: "Devices", glyph: "\u{F0379}" },
    { page: "ports", label: "Open Ports", glyph: "\u{F0528}" },
    { page: "services", label: "Services", glyph: "\u{F004B}" },
    { page: "machine", label: root.selfName !== "" ? root.selfName : "This Machine", glyph: "\u{F0322}" },
    { page: "watch", label: "Vulnerabilities", glyph: "\u{F0499}" },
    { page: "history", label: "History", glyph: "\u{F02DA}" },
    { page: "settings", label: "Settings", glyph: "\u{F0493}" }
  ]

  // Brand
  Text {
    x: root.rail ? 0 : 20
    width: root.rail ? parent.width : -1
    horizontalAlignment: root.rail ? Text.AlignHCenter : Text.AlignLeft
    y: 22
    textFormat: Text.PlainText
    text: "\u{F0437}"
    color: P.accent
    font.family: root.fontMono
    font.pixelSize: root.rail ? 22 : 26
  }

  Column {
    visible: !root.rail
    x: 58
    y: 21
    spacing: 3
    Text {
      textFormat: Text.PlainText
      text: "Port Doctor"
      color: P.text
      font.family: P.sans
      font.pixelSize: 17
      font.weight: Font.DemiBold
    }
    Text {
      textFormat: Text.PlainText
      text: "See Your Network Clearly"
      color: P.secondary
      font.family: P.sans
      font.pixelSize: 10
    }
  }

  Rectangle { x: 12; y: 84; width: parent.width - 24; height: 1; color: P.border }

  // Sections
  Column {
    x: 12
    y: 96
    width: parent.width - 24
    spacing: 2

    Repeater {
      model: root.navModel

      Item {
        required property var modelData
        readonly property bool selected: root.page === modelData.page
        width: parent.width
        height: 38

        Rectangle {
          anchors.fill: parent
          radius: P.radius
          color: parent.selected ? P.raised
            : (navHover.containsMouse ? P.hover : "transparent")
          Behavior on color { ColorAnimation { duration: 90 } }

          Rectangle {
            visible: parent.parent.selected
            width: 2
            radius: 1
            color: P.accent
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 6
            anchors.bottomMargin: 6
          }
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          x: 14
          spacing: 12

          Text {
            textFormat: Text.PlainText
            text: modelData.glyph
            color: parent.parent.selected ? P.accent : P.secondary
            font.family: root.fontMono
            font.pixelSize: 16
            width: 20
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: modelData.label
            color: parent.parent.selected ? P.text : P.secondary
            font.family: P.sans
            font.pixelSize: 12
            font.weight: parent.parent.selected ? Font.Medium : Font.Normal
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          id: navHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.navigate(modelData.page)
        }
      }
    }
  }

  // Scan controls pinned to the bottom.
  Column {
    x: 12
    width: parent.width - 24
    spacing: 10
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 16

    Text {
      visible: !root.rail
      textFormat: Text.PlainText
      text: "SCAN PROFILE"
      color: P.muted
      font.family: P.sans
      font.pixelSize: 10
      font.bold: true
      font.letterSpacing: 1.1
    }

    Rectangle {
      visible: !root.rail
      width: parent.width
      height: 46
      radius: P.radius
      color: P.surface
      border.width: 1
      border.color: profileHover.containsMouse ? P.borderStrong : P.border

      Column {
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1

        Text {
          textFormat: Text.PlainText
          text: root.profile === "quick" ? "Quick Scan" : "Standard Scan"
          color: P.text
          font.family: P.sans
          font.pixelSize: 12
          font.weight: Font.Medium
        }
        Text {
          textFormat: Text.PlainText
          text: root.profile === "quick"
            ? "Discovery ports only, fastest"
            : "Common ports, fast"
          color: P.secondary
          font.family: P.sans
          font.pixelSize: 10
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        text: "⇅"
        color: P.secondary
        font.family: root.fontMono
        font.pixelSize: 11
      }

      MouseArea {
        id: profileHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.profileSelected(root.profile === "quick" ? "standard" : "quick")
      }
    }

    Row {
      visible: !root.rail
      spacing: 6
      Text {
        textFormat: Text.PlainText
        text: "LAST SCAN"
        color: P.muted
        font.family: P.sans
        font.pixelSize: 10
        font.bold: true
        font.letterSpacing: 1.1
        anchors.verticalCenter: parent.verticalCenter
      }
      StatusDot {
        online: true
        visible: root.lastScanAt !== ""
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: root.scanning ? "scanning…" : P.ageText(root.lastScanAt)
        color: P.secondary
        font.family: P.sans
        font.pixelSize: 10
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Rectangle {
      width: parent.width
      height: 34
      radius: P.radius
      color: scanHover.containsMouse ? Qt.lighter(P.accent, 1.08) : P.accent
      opacity: root.scanning ? 0.6 : 1.0
      Behavior on color { ColorAnimation { duration: 90 } }

      Row {
        anchors.centerIn: parent
        spacing: 8
        Text {
          textFormat: Text.PlainText
          text: "\u{F040A}"
          color: "#10151b"
          font.family: root.fontMono
          font.pixelSize: 13
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          textFormat: Text.PlainText
          text: root.scanning ? "Scanning…" : "Scan Network"
          color: "#10151b"
          font.family: P.sans
          font.pixelSize: 12
          font.weight: Font.DemiBold
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      MouseArea {
        id: scanHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.scanning ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!root.scanning) root.scanRequested()
      }
    }
  }
}
