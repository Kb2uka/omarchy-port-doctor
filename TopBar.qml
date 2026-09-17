import QtQuick
import "Palette.js" as P

// Window header: network identity + stats, page tabs, search, actions.
Column {
  id: root

  property string fontMono: "monospace"
  property var network: ({})
  property int hostsOnline: 0
  property int hostsTotal: 0
  property int openPorts: 0
  property string scannedAt: ""
  property bool scanning: false
  property string page: "topology"
  property string topoMode: "map"
  property string searchText: ""

  signal searchEdited(string text)
  signal topoModeSelected(string mode)
  signal navigate(string page)
  signal rescanRequested

  function focusSearch() { searchInput.forceActiveFocus() }

  readonly property var tabModel: [
    { page: "topology", label: "Topology" },
    { page: "devices", label: "Devices" },
    { page: "ports", label: "Open Ports" },
    { page: "services", label: "Services" }
  ]

  height: 104
  spacing: 0

  // -- identity + actions -------------------------------------------------
  Item {
    width: parent.width
    height: 56

    Column {
      x: 20
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2

      Row {
        spacing: 6
        Text {
          textFormat: Text.PlainText
          text: String(root.network.cidr || "no network")
          color: P.text
          font.family: root.fontMono
          font.pixelSize: 15
          font.weight: Font.DemiBold
        }
      }
      Text {
        textFormat: Text.PlainText
        text: root.hostsOnline + " hosts · " + root.openPorts + " open ports · "
          + (root.scanning ? "scanning…" : P.ageText(root.scannedAt))
        color: P.secondary
        font.family: P.sans
        font.pixelSize: 11
      }
    }

    // Search
    Rectangle {
      id: searchBox
      anchors.right: actions.left
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(300, Math.max(180, parent.width * 0.28))
      height: 32
      radius: P.radius
      color: P.surface
      border.width: 1
      border.color: searchInput.activeFocus ? P.accent : P.border

      Text {
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "\u{F0349}"
        color: P.muted
        font.family: root.fontMono
        font.pixelSize: 13
      }

      TextInput {
        id: searchInput
        x: 32
        width: parent.width - 42
        anchors.verticalCenter: parent.verticalCenter
        color: P.text
        font.family: P.sans
        font.pixelSize: 12
        clip: true
        onTextChanged: root.searchEdited(text)
        Text {
          textFormat: Text.PlainText
          anchors.fill: parent
          anchors.verticalCenter: parent.verticalCenter
          verticalAlignment: Text.AlignVCenter
          visible: searchInput.text === "" && !searchInput.activeFocus
          text: "Search devices, IPs, or services…"
          color: P.muted
          font.family: P.sans
          font.pixelSize: 12
        }
      }
    }

    // Refresh + overflow
    Row {
      id: actions
      anchors.right: parent.right
      anchors.rightMargin: 14
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6

      Rectangle {
        width: 32
        height: 32
        radius: P.radius
        color: refreshHover.containsMouse ? P.hover : "transparent"
        border.width: 1
        border.color: refreshHover.containsMouse ? P.borderStrong : P.border

        Text {
          id: refreshGlyph
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "\u{F0450}"
          color: root.scanning ? P.accent : P.secondary
          font.family: root.fontMono
          font.pixelSize: 14
          RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 1000
            loops: Animation.Infinite
            running: root.scanning
            onStopped: refreshGlyph.rotation = 0
          }
        }

        MouseArea {
          id: refreshHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: root.scanning ? Qt.ArrowCursor : Qt.PointingHandCursor
          onClicked: if (!root.scanning) root.rescanRequested()
        }
      }
    }
  }

  // -- tabs ---------------------------------------------------------------
  Item {
    width: parent.width
    height: 48

    Row {
      x: 20
      height: parent.height
      spacing: 22

      Repeater {
        model: root.tabModel

        Item {
          required property var modelData
          readonly property bool selected: root.page === modelData.page
          width: tabLabel.implicitWidth
          height: parent.height

          Text {
            id: tabLabel
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            color: parent.selected ? P.accent
              : (tabHover.containsMouse ? P.text : P.secondary)
            font.family: P.sans
            font.pixelSize: 13
            font.weight: parent.selected ? Font.DemiBold : Font.Normal
            Behavior on color { ColorAnimation { duration: 90 } }
          }

          Rectangle {
            visible: parent.selected
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 2
            radius: 1
            color: P.accent
          }

          MouseArea {
            id: tabHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.navigate(modelData.page)
          }
        }
      }
    }

    // Map / List / Table control, topology page only.
    Row {
      visible: root.page === "topology"
      anchors.right: parent.right
      anchors.rightMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Repeater {
        model: [
          { mode: "map", label: "Map", glyph: "\u{F034D}" },
          { mode: "list", label: "List", glyph: "\u{F0279}" },
          { mode: "table", label: "Table", glyph: "\u{F04BA}" }
        ]

        Rectangle {
          id: modeChip
          required property var modelData
          required property int index
          readonly property bool selected: root.topoMode === modelData.mode
          width: modeLabel.implicitWidth + 30
          height: 28
          radius: 0
          color: selected ? P.accentSoft
            : (modeHover.containsMouse ? P.hover : "transparent")
          border.width: 1
          border.color: selected ? P.accent : P.border

          Row {
            anchors.centerIn: parent
            spacing: 6
            Text {
              textFormat: Text.PlainText
              text: modelData.glyph
              color: modeChip.selected ? P.accent : P.secondary
              font.family: root.fontMono
              font.pixelSize: 12
            }
            Text {
              id: modeLabel
              textFormat: Text.PlainText
              text: modelData.label
              color: modeChip.selected ? P.accent : P.secondary
              font.family: P.sans
              font.pixelSize: 11
            }
          }

          MouseArea {
            id: modeHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.topoModeSelected(modelData.mode)
          }
        }
      }
    }
  }
}
