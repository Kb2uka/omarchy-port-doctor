import QtQuick
import "Palette.js" as P

// Devices page: the full-height device table.
Item {
  id: root
  property string fontMono: "monospace"
  property var hosts: []
  signal hostSelected(string ip)

  DeviceTable {
    anchors.fill: parent
    anchors.margins: 18
    fontMono: root.fontMono
    hosts: root.hosts
    title: "Devices on Your Network"
    compact: false
    onHostSelected: function(ip) { root.hostSelected(ip) }
  }
}
