.pragma library

// Port Doctor visual system: near-black charcoal, thin slate borders,
// burnt orange reserved for selection and primary action, teal/blue/green
// restrained status accents.
var background = "#0b0f14"
var sidebar = "#080d12"
var surface = "#12181f"
var raised = "#1a222c"
var hover = "#161e27"
var border = "#1f2832"
var borderStrong = "#2b3744"
var text = "#e9edf2"
var secondary = "#8b98a5"
var muted = "#5f6b77"
var accent = "#e07a3a"      // burnt orange: selection, primary action
var accentSoft = "#3a2a1e"
var teal = "#3aa99a"
var blue = "#4a90c2"
var green = "#46a36e"
var red = "#c2554a"

var sans = "Noto Sans"
var radius = 6
var gap = 12

function alpha(hex, a) {
    var c = hex
    if (typeof c === "string") {
        var h = c.replace("#", "")
        var r = parseInt(h.substr(0, 2), 16) / 255
        var g = parseInt(h.substr(2, 2), 16) / 255
        var b = parseInt(h.substr(4, 2), 16) / 255
        return Qt.rgba(r, g, b, a)
    }
    return Qt.rgba(c.r, c.g, c.b, a)
}

// Service-class hues as real color values (canvas-safe).
function classColor(klass) {
    switch (String(klass)) {
    case "remote": return Qt.rgba(0.357, 0.553, 0.937)
    case "web": return Qt.rgba(0.247, 0.663, 0.486)
    case "media": return Qt.rgba(0.608, 0.549, 1.0)
    case "file": return Qt.rgba(0.898, 0.753, 0.482)
    case "print": return Qt.rgba(0.604, 0.655, 0.690)
    case "iot": return Qt.rgba(0.949, 0.471, 0.624)
    case "db": return Qt.rgba(0.949, 0.631, 0.329)
    case "mail": return Qt.rgba(0.400, 0.761, 0.820)
    case "infra": return Qt.rgba(0.647, 0.706, 0.988)
    default: return Qt.rgba(0.62, 0.67, 0.72, 1)
    }
}

function ageText(iso) {
    if (!iso) return "never"
    var then = new Date(iso)
    if (isNaN(then.getTime())) return "never"
    var s = Math.max(0, Math.round((Date.now() - then.getTime()) / 1000))
    if (s < 5) return "just now"
    if (s < 60) return s + "s ago"
    var m = Math.floor(s / 60)
    if (m === 1) return "1 minute ago"
    if (m < 60) return m + " minutes ago"
    var h = Math.floor(m / 60)
    if (h === 1) return "1 hour ago"
    return h + " hours ago"
}
