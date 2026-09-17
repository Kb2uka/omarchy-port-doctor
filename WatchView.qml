import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// Vulnerabilities page: connect-scan exposure observations. These are not
// CVE matches — the scanner only knows which ports answered, so every row
// names its evidence and stays honest about the limit.
Item {
  id: root
  property string fontMono: "monospace"
  property var hosts: []
  property var network: ({})

  function hostLabel(h) {
    var nm = String(h.hostname || "")
    if (nm !== "") return nm.replace(/\.local$/, "")
    return String(h.ip)
  }

  readonly property var findings: {
    var out = []
    function add(host, port, service, severity, title, detail) {
      out.push({ ip: host.ip, hostLabel: hostLabel(host), port: port,
                 service: service, severity: severity, title: title,
                 detail: detail })
    }
    for (var i = 0; i < hosts.length; i++) {
      var h = hosts[i]
      var ports = h.ports || []
      for (var j = 0; j < ports.length; j++) {
        var p = ports[j].port
        if (p === 23 || p === 2323)
          add(h, p, "telnet", "review", "Telnet is plaintext",
              "Credentials and traffic cross the LAN unencrypted. SSH is the safe replacement.")
        else if (p === 21)
          add(h, p, "ftp", "review", "FTP is plaintext",
              "FTP sends credentials unencrypted. Prefer SFTP or a share instead.")
        else if (p === 3306 || p === 5432 || p === 6379 || p === 27017)
          add(h, p, ports[j].service, "review", "Database reachable from the LAN",
              "Any device on the network can attempt a login. Bind to loopback unless the LAN needs it.")
        else if (p === 5900 || p === 5901)
          add(h, p, "vnc", "review", "VNC remote desktop reachable",
              "VNC auth is weak by design. Keep it loopback-only or tunnel it over SSH.")
        else if (p === 3389)
          add(h, p, "rdp", "note", "Remote Desktop reachable from the LAN",
              "Expected on Windows hosts; worth knowing it answers here.")
        else if (p === 9100)
          add(h, p, "jetdirect", "note", "Raw printer port open",
              "Port 9100 prints whatever it receives. Fine on a trusted LAN.")
        else if (p === 1883)
          add(h, p, "mqtt", "note", "MQTT broker reachable",
              "Home-automation brokers often allow anonymous reads. Check its ACL.")
        else if (p === 8080 || p === 8000 || p === 3000 || p === 5000
                 || p === 8888 || p === 8081)
          add(h, p, ports[j].service, "note", "Web admin or dev server",
              "Alternate web ports often hold admin panels. Confirm it asks for a login.")
        else if (p === 53 && !h.isGateway)
          add(h, p, "dns", "note", "DNS resolver on a non-gateway host",
              "Pi-hole or a resolver appliance is fine; just know it is answering.")
      }
    }
    var rank = { review: 0, note: 1 }
    out.sort(function(a, b) { return rank[a.severity] - rank[b.severity] })
    return out
  }

  Column {
    anchors.fill: parent
    anchors.margins: 18
    spacing: 12

    Row {
      spacing: 10
      Text {
        textFormat: Text.PlainText
        text: "Vulnerabilities"
        color: P.text
        font.family: P.sans
        font.pixelSize: 15
        font.weight: Font.DemiBold
      }
      Text {
        textFormat: Text.PlainText
        text: root.findings.length + " observations"
        color: P.muted
        font.family: P.sans
        font.pixelSize: 11
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Rectangle {
      width: parent.width
      height: 30
      radius: P.radius
      color: P.alpha(P.blue, 0.08)
      border.width: 1
      border.color: P.alpha(P.blue, 0.25)
      Text {
        textFormat: Text.PlainText
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - 20
        elide: Text.ElideRight
        text: "Connect-scan observations only, not a CVE audit. Evidence is the answering port."
        color: P.secondary
        font.family: P.sans
        font.pixelSize: 10
      }
    }

    Flickable {
      width: parent.width
      height: parent.height - 52 - parent.spacing * 2
      contentWidth: width
      contentHeight: findingColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: findingColumn
        width: parent.width
        spacing: 8

        Repeater {
          model: root.findings

          Rectangle {
            id: findingCard
            required property var modelData
            readonly property bool review: modelData.severity === "review"
            width: findingColumn.width
            height: 54
            radius: P.radius
            color: P.surface
            border.width: 1
            border.color: review ? P.alpha(P.accent, 0.35) : P.border

            Row {
              x: 12
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 24
              spacing: 12

              Rectangle {
                width: 8
                height: 8
                radius: 2
                color: findingCard.review ? P.accent : P.blue
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width * 0.42
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  textFormat: Text.PlainText
                  text: findingCard.modelData.title
                  color: P.text
                  font.family: P.sans
                  font.pixelSize: 12
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                  width: parent.width
                }
                Text {
                  textFormat: Text.PlainText
                  text: findingCard.modelData.hostLabel
                    + "  ·  " + findingCard.modelData.ip
                    + "  ·  port " + findingCard.modelData.port
                  color: P.muted
                  font.family: P.sans
                  font.pixelSize: 10
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.5
                anchors.verticalCenter: parent.verticalCenter
                text: findingCard.modelData.detail
                color: P.secondary
                font.family: P.sans
                font.pixelSize: 10
                elide: Text.ElideRight
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.findings.length === 0
          width: parent.width
          topPadding: 30
          horizontalAlignment: Text.AlignHCenter
          text: "Nothing stands out in the latest scan.\nOpen ports exist, but none match the watch rules."
          color: P.muted
          font.family: P.sans
          font.pixelSize: 12
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
