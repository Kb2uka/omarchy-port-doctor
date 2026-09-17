import QtQuick

// One MDI glyph per device type, drawn in the theme's Nerd Font so stroke
// weight, size, and alignment stay coherent across every device.
Text {
    id: root
    property string type: "unknown"
    property color ink: "#8b98a5"
    property real glyphSize: 22
    property string fontFamily: "monospace"

    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    color: ink
    font.family: fontFamily
    font.pixelSize: glyphSize
    renderType: Text.NativeRendering

    text: {
      switch (String(root.type)) {
        case "router": return "\u{F0317}"        // lan
        case "laptop": return "\u{F0322}"        // laptop
        case "desktop": return "\u{F0379}"       // monitor
        case "computer": return "\u{F0379}"
        case "nas": return "\u{F030D}"           // server-network
        case "server": return "\u{F048B}"        // server
        case "raspberry-pi": return "\u{F043F}"  // raspberry-pi
        case "printer": return "\u{F042A}"       // printer
        case "camera": return "\u{F07AE}"        // cctv
        case "tv": return "\u{F0502}"            // television
        case "phone": return "\u{F011C}"         // cellphone
        case "tablet": return "\u{F04F6}"        // tablet
        case "console": return "\u{F0297}"       // gamepad-variant
        case "iot": return "\u{F07D0}"           // home-automation
        default: return "\u{F0FB0}"             // devices
      }
    }
}
