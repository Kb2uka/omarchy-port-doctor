#!/usr/bin/env bash
# Load the plugin natively under a headless Weston compositor and cycle the
# window through every page. Fails on any QML error in the shell log. The
# scanner shim is replaced with a fixture stub so the harness renders
# realistic data without sending any network traffic. Two passes: a small
# eight-host network and, via PD_FIXTURE=large, a dense multi-network census
# so the map's large-network layout is exercised too.
set -euo pipefail
cd "$(dirname "$0")/../.."
art="$PWD/.artifacts/feat_port_doctor"
mkdir -p "$art"

harness="$(mktemp -d /tmp/pd-native-XXXXXX)"
weston_pid=""
cleanup() {
  if [[ -n "$weston_pid" ]]; then kill "$weston_pid" 2>/dev/null || true; wait "$weston_pid" 2>/dev/null || true; fi
  rm -rf "$harness"
}
trap cleanup EXIT
mkdir -p "$harness/deck" "$harness/runtime" "$harness/state"
chmod 700 "$harness/runtime" "$harness/state"
cp ./*.qml ./*.js "$harness/deck/"
cat > "$harness/deck/port-doctor.py" <<'STUB'
#!/usr/bin/python3 -I
"""Fixture stand-in for the real scanner: canned payloads, no network."""
import json
import os
import sys

LAN = {
    "version": 1, "mode": "lan", "scannedAt": "2026-09-17T12:00:00+00:00",
    "error": None, "profile": "standard",
    "identity": {"hostname": "xps16", "model": "XPS 16 DA16260",
                 "manufacturer": "Dell Inc.", "label": "xps16"},
    "controller": {"configured": True, "host": "192.168.4.1",
                   "site": "default", "clients": 8, "error": None},
    "network": {"cidr": "192.168.4.0/24", "ifname": "wlan0",
                "selfIp": "192.168.4.19", "gateway": "192.168.4.1",
                "truncated": False, "passiveOnly": False, "note": ""},
    "hosts": [
        {"ip": "192.168.4.1", "hostname": "unifi.localdomain",
         "mac": "f0:9f:c2:11:22:33", "macPrivate": False, "vendor": "Ubiquiti",
         "isSelf": False, "isGateway": True, "via": "scan", "latencyMs": 1.2,
         "type": "router", "network": "Home", "vlan": 0, "remoteNet": False,
         "ports": [{"port": 53, "proto": "tcp", "service": "dns", "class": "infra"},
                   {"port": 443, "proto": "tcp", "service": "https", "class": "web"}]},
        {"ip": "192.168.4.19", "hostname": "xps16",
         "mac": "dc:54:75:aa:bb:cc", "macPrivate": False, "vendor": "",
         "isSelf": True, "isGateway": False, "via": "scan", "latencyMs": 0.4,
         "type": "laptop", "network": "Home", "vlan": 0, "remoteNet": False,
         "ports": [{"port": 22, "proto": "tcp", "service": "ssh", "class": "remote"}]},
        {"ip": "192.168.4.20", "hostname": "truenas.local",
         "mac": "00:11:32:dd:ee:ff", "macPrivate": False, "vendor": "Synology",
         "isSelf": False, "isGateway": False, "via": "scan", "latencyMs": 4.1,
         "type": "nas", "network": "Home", "vlan": 0, "remoteNet": False,
         "ports": [{"port": 445, "proto": "tcp", "service": "smb", "class": "file"},
                   {"port": 5000, "proto": "tcp", "service": "dev-http", "class": "web"}]},
        {"ip": "192.168.4.22", "hostname": "pi-hole.local",
         "mac": "b8:27:eb:aa:bb:cc", "macPrivate": False, "vendor": "Raspberry Pi",
         "isSelf": False, "isGateway": False, "via": "scan", "latencyMs": 2.0,
         "type": "raspberry-pi", "network": "Home", "vlan": 0, "remoteNet": False,
         "ports": [{"port": 53, "proto": "tcp", "service": "dns", "class": "infra"}]},
        {"ip": "192.168.4.23", "hostname": "",
         "mac": "fc:3f:db:11:22:33", "macPrivate": False, "vendor": "HP",
         "isSelf": False, "isGateway": False, "via": "scan", "latencyMs": 9.2,
         "type": "printer", "network": "Home", "vlan": 0, "remoteNet": False,
         "ports": [{"port": 9100, "proto": "tcp", "service": "jetdirect", "class": "print"}]},
        {"ip": "192.168.4.27", "hostname": "iPad-2.local",
         "mac": "3c:22:fb:44:55:66", "macPrivate": False, "vendor": "Apple",
         "isSelf": False, "isGateway": False, "via": "neigh", "latencyMs": None,
         "type": "tablet", "network": "Home", "vlan": 0, "remoteNet": False,
         "ports": []},
        {"ip": "10.70.0.42", "hostname": "studio",
         "mac": "a4:b1:97:11:22:33", "macPrivate": False, "vendor": "Apple",
         "isSelf": False, "isGateway": False, "via": "unifi", "latencyMs": 3.8,
         "type": "desktop", "network": "Studio", "vlan": 10, "remoteNet": True,
         "ports": [{"port": 22, "proto": "tcp", "service": "ssh", "class": "remote"},
                   {"port": 11434, "proto": "tcp", "service": "ollama", "class": "dev"}]},
        {"ip": "10.70.90.20", "hostname": "echo-kitchen",
         "mac": "40:b4:cd:44:55:66", "macPrivate": False, "vendor": "Amazon",
         "isSelf": False, "isGateway": False, "via": "unifi", "latencyMs": None,
         "type": "iot", "network": "IoT", "vlan": 3, "remoteNet": True,
         "ports": []}
    ],
    "stats": {"targets": 254, "hostsUp": 8, "openPorts": 9,
              "scanMs": 4600, "discoveryMs": 1500, "controllerMs": 180,
              "deadlineHit": False}
}


def large_lan():
    """A dense controller census: four networks, dozens of hosts, so the
    map's clustered large-network layout gets exercised natively."""
    hosts = [
        {"ip": "10.70.120.1", "hostname": "unifi.localdomain",
         "mac": "f0:9f:c2:11:22:33", "macPrivate": False, "vendor": "Ubiquiti",
         "isSelf": False, "isGateway": True, "via": "scan", "latencyMs": 1.1,
         "type": "router", "network": "SHACK", "vlan": 0, "remoteNet": False,
         "ports": [{"port": 53, "proto": "tcp", "service": "dns", "class": "infra"},
                   {"port": 443, "proto": "tcp", "service": "https", "class": "web"}]},
        {"ip": "10.70.120.149", "hostname": "xps16",
         "mac": "dc:54:75:aa:bb:cc", "macPrivate": False, "vendor": "Dell",
         "isSelf": True, "isGateway": False, "via": "scan", "latencyMs": 0.3,
         "type": "laptop", "network": "SHACK", "vlan": 0, "remoteNet": False,
         "ports": [{"port": 22, "proto": "tcp", "service": "ssh", "class": "remote"}]},
    ]
    shack = [
        ("homebase", "10.70.120.219", "server", "Dell", [22, 445]),
        ("optiplex", "10.70.120.135", "desktop", "Dell", [22]),
        ("g2pi", "10.70.120.152", "raspberry-pi", "Raspberry Pi", [22]),
        ("raspberrypi", "10.70.120.41", "raspberry-pi", "Raspberry Pi", [22, 80]),
        ("windows-gb2j9c", "10.70.120.88", "desktop", "", [3389]),
        ("jillians-air", "10.70.120.96", "laptop", "Apple", []),
        ("carters-pc", "10.70.120.104", "desktop", "", [3389]),
        ("machio-c", "10.70.120.133", "desktop", "", []),
        ("dreame-vacuum-r5c", "10.70.120.146", "iot", "Dreame", []),
        ("amazon-391af1e8", "10.70.120.158", "iot", "Amazon", []),
    ]
    default = [
        ("studio", "10.70.0.42", "desktop", "Apple", [22, 11434]),
        ("tower", "10.70.0.159", "server", "", [22, 445]),
        ("windows-ci-1", "10.70.0.26", "desktop", "", [3389]),
        ("windows-ci-2", "10.70.0.27", "desktop", "", [3389]),
        ("windows-ci-3", "10.70.0.110", "desktop", "", []),
        ("windows-test", "10.70.0.225", "desktop", "", [3389]),
        ("linux-ci-2", "10.70.0.10", "server", "", [22]),
        ("zeusagent", "10.70.0.25", "server", "", [22]),
        ("dougs-mac-mini", "10.70.0.71", "desktop", "Apple", [22]),
        ("studios-imac-2", "10.70.0.73", "desktop", "Apple", []),
    ]
    iot = [
        ("ringspotlightcam-f6", "10.70.90.171", "camera", "Ring", []),
        ("ringspotlightcam-5f", "10.70.90.172", "camera", "Ring", []),
        ("ringstickupcam-56", "10.70.90.173", "camera", "Ring", []),
        ("ringstickupcam-fa", "10.70.90.174", "camera", "Ring", [554]),
        ("ringdoorbell-00", "10.70.90.85", "camera", "Ring", []),
        ("amazon-smart-tv", "10.70.90.123", "tv", "Amazon", []),
        ("amazon-e35ba17", "10.70.90.57", "iot", "Amazon", []),
        ("echo-kitchen", "10.70.90.20", "iot", "Amazon", []),
        ("echo-office", "10.70.90.21", "iot", "Amazon", []),
        ("firetv-living", "10.70.90.99", "tv", "Amazon", []),
        ("wyze-cam-garage", "10.70.90.140", "camera", "Wyze", [554]),
        ("tuya-plug-bench", "10.70.90.141", "iot", "Tuya", []),
        ("hp-printer", "10.70.90.60", "printer", "HP", [9100]),
        ("nest-thermostat", "10.70.90.61", "iot", "Google", []),
        ("roborock-s7", "10.70.90.62", "iot", "Roborock", []),
        ("blink-sync", "10.70.90.63", "camera", "Blink", []),
        ("wled-shelf", "10.70.90.64", "iot", "", [80]),
        ("esphome-sensor1", "10.70.90.65", "iot", "", []),
    ]
    vpn = [
        ("amandas-air", "192.168.3.2", "laptop", "Apple", []),
        ("iphone-kb2uka", "192.168.3.4", "phone", "Apple", []),
    ]

    def emit(rows, network, vlan, routed):
        for name, ip, kind, vendor, ports in rows:
            hosts.append({
                "ip": ip, "hostname": name,
                "mac": "02:11:22:" + ":".join(ip.split(".")[1:]),
                "macPrivate": vendor == "", "vendor": vendor,
                "isSelf": False, "isGateway": False,
                "via": "unifi" if routed else "scan",
                "latencyMs": None if routed else 2.4,
                "type": kind, "network": network, "vlan": vlan,
                "remoteNet": routed,
                "ports": [{"port": p, "proto": "tcp", "service": "svc",
                           "class": "infra"} for p in ports]})

    emit(shack, "SHACK", 0, False)
    emit(default, "Default", 1, True)
    emit(iot, "IoT", 3, True)
    emit(vpn, "WireGuard", 9, True)
    open_ports = sum(len(h["ports"]) for h in hosts)
    return {
        "version": 1, "mode": "lan", "scannedAt": "2026-09-17T12:00:00+00:00",
        "error": None, "profile": "standard",
        "identity": {"hostname": "xps16", "model": "XPS 16 DA16260",
                     "manufacturer": "Dell Inc.", "label": "xps16"},
        "controller": {"configured": True, "host": "10.70.120.1",
                       "site": "default", "clients": len(hosts), "error": None},
        "network": {"cidr": "10.70.120.0/24", "ifname": "eth0",
                    "selfIp": "10.70.120.149", "gateway": "10.70.120.1",
                    "truncated": False, "passiveOnly": False, "note": ""},
        "hosts": hosts,
        "stats": {"targets": 254, "hostsUp": len(hosts), "openPorts": open_ports,
                  "scanMs": 9800, "discoveryMs": 2100, "controllerMs": 240,
                  "deadlineHit": False}
    }


MACHINE = {
    "version": 1, "mode": "machine", "scannedAt": "2026-09-17T12:00:00+00:00",
    "error": None, "hostname": "xps16",
    "identity": {"hostname": "xps16", "model": "XPS 16 DA16260",
                 "manufacturer": "Dell Inc.", "label": "xps16"},
    "listeners": [
        {"proto": "tcp", "port": 22, "bind": "0.0.0.0",
         "scope": "all interfaces", "process": "sshd", "pid": 812,
         "service": "ssh", "class": "remote"},
        {"proto": "tcp", "port": 631, "bind": "127.0.0.1",
         "scope": "loopback only", "process": "cupsd", "pid": 900,
         "service": "ipp", "class": "print"},
        {"proto": "udp", "port": 5353, "bind": "0.0.0.0",
         "scope": "all interfaces", "process": "", "pid": None,
         "service": "mdns", "class": "infra"}
    ],
    "connections": [
        {"proto": "tcp", "state": "established", "localIp": "192.168.4.19",
         "localPort": 51234, "remoteIp": "192.168.4.1", "remotePort": 443,
         "remoteKind": "lan", "process": "firefox", "pid": 1200,
         "remoteName": "unifi.localdomain"},
        {"proto": "tcp", "state": "established", "localIp": "192.168.4.19",
         "localPort": 51240, "remoteIp": "142.250.80.46", "remotePort": 443,
         "remoteKind": "internet", "process": "firefox", "pid": 1200,
         "remoteName": ""},
        {"proto": "udp", "state": "connected", "localIp": "192.168.4.19",
         "localPort": 53530, "remoteIp": "192.168.4.22", "remotePort": 53,
         "remoteKind": "lan", "process": "", "pid": None,
         "remoteName": "pi-hole.local"}
    ],
    "stats": {"listeners": 3, "connections": 3,
              "truncatedListeners": 0, "truncatedConnections": 0}
}

mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode in ("lan", "lan-quick"):
    payload = large_lan() if os.environ.get("PD_FIXTURE") == "large" else LAN
    print(json.dumps(payload, separators=(",", ":")))
elif mode == "machine":
    print(json.dumps(MACHINE, separators=(",", ":")))
else:
    sys.exit(2)
STUB
cp -r /usr/share/omarchy/shell/Ui /usr/share/omarchy/shell/Commons "$harness/"
cat > "$harness/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "deck" as Deck

ShellRoot {
  Deck.Panel { id: plugin }
  Timer { interval: 500; running: true; onTriggered: plugin.open() }
  Timer { interval: 1100; running: true; onTriggered: plugin.setPage("devices") }
  Timer { interval: 1500; running: true; onTriggered: plugin.setPage("ports") }
  Timer { interval: 1700; running: true; onTriggered: plugin.setPage("services") }
  Timer { interval: 2100; running: true; onTriggered: plugin.setPage("machine") }
  Timer { interval: 2500; running: true; onTriggered: plugin.setPage("watch") }
  Timer { interval: 2900; running: true; onTriggered: plugin.setPage("history") }
  Timer { interval: 3300; running: true; onTriggered: plugin.setPage("settings") }
  Timer { interval: 3700; running: true; onTriggered: plugin.setPage("topology") }
  Timer { interval: 4100; running: true; onTriggered: plugin.close() }
  Timer { interval: 4400; running: true; onTriggered: Qt.quit() }
}
QML
export XDG_RUNTIME_DIR="$harness/runtime"
export XDG_STATE_HOME="$harness/state"
export WAYLAND_DISPLAY=pd-wayland

# A weston tree extracted outside the system root needs its module dirs
# overlaid onto /usr/lib without touching the host: merge via symlinks and
# bind the merged view read-only inside a bubblewrap sandbox.
weston_launch=()
if [[ -n "${WESTON_ROOT:-}" ]]; then
  merged="$harness/libmerge"
  hostlib="$harness/hostlib"
  mkdir -p "$merged" "$hostlib"
  for entry in /usr/lib/*; do ln -s "$hostlib/$(basename "$entry")" "$merged/$(basename "$entry")"; done
  ln -sfn "$WESTON_ROOT/usr/lib/libweston-15" "$merged/libweston-15"
  ln -sfn "$WESTON_ROOT/usr/lib/weston" "$merged/weston"
  WESTON_BIN="$WESTON_ROOT/usr/bin/weston"
  weston_libs="$WESTON_ROOT/usr/lib/weston:$WESTON_ROOT/usr/lib"
  weston_launch=(bwrap --dev-bind / / --ro-bind /usr/lib "$hostlib"
    --ro-bind "$merged" /usr/lib
    --setenv LD_LIBRARY_PATH "$weston_libs" --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR" --)
fi

"${weston_launch[@]}" "${WESTON_BIN:-weston}" --backend="${WESTON_BACKEND:-headless}" --shell="${WESTON_SHELL:-kiosk-shell.so}" --renderer=pixman --width=1500 --height=1000 \
  --socket="$WAYLAND_DISPLAY" --idle-time=0 --no-config > "$art/weston.log" 2>&1 &
weston_pid=$!
for attempt in {1..50}; do
  [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break
  kill -0 "$weston_pid" 2>/dev/null || { cat "$art/weston.log"; exit 1; }
  sleep 0.1
done

run_pass() {
  local fixture="$1" log="$2"
  PD_FIXTURE="$fixture" QT_QPA_PLATFORM=wayland python3 tests/ui/native-run.py "$harness" "$log"
  cat "$log"
  grep -q 'Configuration Loaded' "$log"
  ! grep -Eq 'ERROR|ReferenceError|TypeError|is not a type|Cannot assign|Required property' "$log"
}

run_pass small "$art/native-parse.log"
run_pass large "$art/native-parse-large.log"
