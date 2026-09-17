"""Best-effort device typing from evidence the scanner already has.

Every rule here is a labeled heuristic: the answer comes from the gateway
flag, the OUI vendor, the hostname, the open ports, or the local machine's
own chassis type. When none of that speaks, the type is "unknown" — never
a fabricated guess.
"""

import os


def _chassis_type(sys_root="/sys"):
    """'laptop' | 'desktop' | 'computer' for this machine, from DMI."""
    try:
        with open(os.path.join(sys_root, "class", "dmi", "id", "chassis_type"),
                  "r", errors="replace") as handle:
            value = handle.read(8).strip()
    except OSError:
        return "computer"
    if value in ("31", "32", "30", "34"):
        return "laptop"
    if value in ("3", "4", "5", "6", "7", "13", "15", "16"):
        return "desktop"
    return "computer"


_CAMERA_NAMES = ("cam", "reolink", "hikvision", "dahua", "ring", "wyze",
                 "amcrest", "doorbell")
_TV_NAMES = ("tv", "bravia", "roku", "firetv", "fire-tv", "appletv",
             "apple-tv", "chromecast", "shield")
_NAS_NAMES = ("nas", "diskstation", "ds918", "ds920", "qnap", "truenas",
              "freenas", "unraid", "synology")
_CONSOLE_NAMES = ("xbox", "playstation", "ps5", "ps4", "nintendo", "switch")


def _has(ports, *numbers):
    return any(number in ports for number in numbers)


def classify(host, chassis=None):
    """Device type for one scanned host.

    Types: router, laptop, desktop, computer, nas, raspberry-pi, printer,
    camera, tv, phone, tablet, console, iot, unknown.
    """
    if host.get("isGateway"):
        return "router"

    ports = {p["port"] for p in host.get("ports", []) if isinstance(p, dict)}
    vendor = str(host.get("vendor") or "")
    name = str(host.get("hostname") or "").lower()

    if host.get("isSelf"):
        return chassis if chassis is not None else _chassis_type()

    if "eero" in name or "airport" in name or "extender" in name:
        return "router"
    if "macbook" in name:
        return "laptop"
    if "mac-mini" in name or "mac mini" in name or "imac" in name:
        return "desktop"
    if name.startswith("mac-") or name.endswith("-mac"):
        return "computer"

    if vendor == "Raspberry Pi":
        return "raspberry-pi"

    if "iphone" in name or "android" in name or "pixel" in name:
        return "phone"
    if "ipad" in name:
        return "tablet"

    if any(token in name for token in _CAMERA_NAMES):
        return "camera"
    if _has(ports, 554) and not _has(ports, 22, 445, 3389):
        # RTSP without computer services: almost always a camera or NVR.
        return "camera"

    if any(token in name for token in _CONSOLE_NAMES):
        return "console"
    if vendor == "Microsoft" and not _has(ports, 445, 3389, 22):
        # A Microsoft OUI with no Windows services is more Xbox than PC.
        return "console"

    if any(token in name for token in _NAS_NAMES) or vendor == "Synology":
        return "nas"
    if vendor == "QNAP":
        return "nas"

    if _has(ports, 9100):
        return "printer"
    if vendor in ("HP", "Brother", "Epson", "Canon") and _has(ports, 631, 515):
        return "printer"

    if vendor == "Roku" or any(token in name for token in _TV_NAMES):
        return "tv"
    if vendor in ("LG", "Samsung", "Sony") and _has(ports, 8009, 7000, 8060):
        return "tv"

    if vendor == "Espressif" or _has(ports, 1883, 8883, 5683):
        return "iot"
    if "homeassistant" in name or "home-assistant" in name or "hass" in name:
        return "iot"

    if _has(ports, 445, 548) and _has(ports, 5000, 5001):
        return "nas"

    if vendor in ("Apple", "Dell", "HP", "ASUS", "Intel", "Microsoft",
                  "Lenovo", "QEMU/KVM", "VMware", "VirtualBox", "Hyper-V"):
        return "computer"

    return "unknown"
