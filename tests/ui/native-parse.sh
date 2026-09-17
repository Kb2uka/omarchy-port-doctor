#!/usr/bin/env bash
# Load the plugin's QML natively under a headless Weston compositor and
# exercise both views plus open/close cycles. Fails on any QML error in the
# shell log. The scanner shim is replaced with a fixture stub so the harness
# renders realistic rows without sending any network traffic.
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
cp ./Panel.qml "$harness/deck/"
cat > "$harness/deck/port-doctor.py" <<'STUB'
#!/usr/bin/python3 -I
"""Fixture stand-in for the real scanner: canned payloads, no network."""
import json
import sys

LAN = {
    "version": 1, "mode": "lan", "scannedAt": "2026-09-17T12:00:00+00:00",
    "error": None,
    "network": {"cidr": "10.70.120.0/24", "ifname": "wlan0",
                "selfIp": "10.70.120.50", "gateway": "10.70.120.1",
                "truncated": False, "passiveOnly": False, "note": ""},
    "hosts": [
        {"ip": "10.70.120.1", "hostname": "gateway", "mac": "f0:9f:c2:11:22:33",
         "vendor": "Ubiquiti", "isSelf": False, "isGateway": True,
         "via": "scan", "latencyMs": 1.2,
         "ports": [{"port": 53, "proto": "tcp", "service": "dns", "class": "infra"},
                   {"port": 443, "proto": "tcp", "service": "https", "class": "web"}]},
        {"ip": "10.70.120.50", "hostname": "xps16", "mac": "dc:54:75:aa:bb:cc",
         "vendor": "", "isSelf": True, "isGateway": False,
         "via": "scan", "latencyMs": 0.4,
         "ports": [{"port": 22, "proto": "tcp", "service": "ssh", "class": "remote"}]},
        {"ip": "10.70.120.99", "hostname": "", "mac": "b8:27:eb:aa:bb:cc",
         "vendor": "Raspberry Pi", "isSelf": False, "isGateway": False,
         "via": "neigh", "latencyMs": None, "ports": []}
    ],
    "stats": {"targets": 254, "hostsUp": 3, "openPorts": 3,
              "scanMs": 1800, "discoveryMs": 900, "deadlineHit": False}
}

MACHINE = {
    "version": 1, "mode": "machine", "scannedAt": "2026-09-17T12:00:00+00:00",
    "error": None, "hostname": "xps16",
    "listeners": [
        {"proto": "tcp", "port": 22, "bind": "0.0.0.0",
         "scope": "all interfaces", "process": "sshd", "pid": 812},
        {"proto": "tcp", "port": 631, "bind": "127.0.0.1",
         "scope": "loopback only", "process": "cupsd", "pid": 900},
        {"proto": "udp", "port": 5353, "bind": "0.0.0.0",
         "scope": "all interfaces", "process": "", "pid": None}
    ],
    "connections": [
        {"proto": "tcp", "state": "established", "localIp": "10.70.120.50",
         "localPort": 51234, "remoteIp": "10.70.120.1", "remotePort": 443,
         "remoteKind": "lan", "process": "firefox", "pid": 1200,
         "remoteName": "gateway"},
        {"proto": "tcp", "state": "established", "localIp": "10.70.120.50",
         "localPort": 51240, "remoteIp": "142.250.80.46", "remotePort": 443,
         "remoteKind": "internet", "process": "firefox", "pid": 1200,
         "remoteName": ""},
        {"proto": "tcp", "state": "time-wait", "localIp": "127.0.0.1",
         "localPort": 44122, "remoteIp": "127.0.0.1", "remotePort": 8080,
         "remoteKind": "loopback", "process": "", "pid": None, "remoteName": ""}
    ],
    "stats": {"listeners": 3, "connections": 3,
              "truncatedListeners": 0, "truncatedConnections": 0}
}

mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode == "lan":
    print(json.dumps(LAN, separators=(",", ":")))
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
  // The smallest bar object that satisfies the panel's API surface.
  QtObject {
    id: fakeBar
    property string position: "top"
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property real barSize: 32
    property color foreground: "#ffffff"
    property color barForeground: "#ffffff"
    property color urgent: "#ff5555"
    property string fontFamily: "sans-serif"
    property var activePopout: null
    property var clickTargets: []
    function requestPopout(key) { activePopout = key }
    function releasePopout(key) { if (activePopout === key) activePopout = null }
    function switchPanelFrom(panel, direction) { return false }
    function targetBelongsToWindow(target, window) { return true }
    function hideTooltip(item) {}
    function registerClickTarget(item) { clickTargets.push(item) }
    function unregisterClickTarget(item) {
      clickTargets = clickTargets.filter(function(target) { return target !== item })
    }
  }

  Deck.Panel { id: plugin; bar: fakeBar }
  Timer { interval: 400; running: true; onTriggered: plugin.open() }
  Timer { interval: 1000; running: true; onTriggered: plugin.switchView(1) }
  Timer { interval: 1500; running: true; onTriggered: plugin.switchView(1) }
  Timer { interval: 1800; running: true; onTriggered: plugin.rescanLan() }
  Timer { interval: 2100; running: true; onTriggered: plugin.close() }
  Timer { interval: 2400; running: true; onTriggered: plugin.toggle() }
  Timer { interval: 2900; running: true; onTriggered: Qt.quit() }
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
QT_QPA_PLATFORM=wayland python3 tests/ui/native-run.py "$harness" "$art/native-parse.log"
cat "$art/native-parse.log"
rg -q 'Configuration Loaded' "$art/native-parse.log"
! rg -q 'ERROR|ReferenceError|TypeError|is not a type|Cannot assign|Required property' "$art/native-parse.log"
