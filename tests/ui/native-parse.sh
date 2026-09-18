#!/usr/bin/env bash
# Load the plugin natively under a headless Weston compositor and cycle the
# window through every page. Fails on any QML error in the shell log. The
# scanner shim is replaced with a fixture stub so the harness renders
# realistic data without sending any network traffic. Three census sizes
# (PD_FIXTURE=small|medium|large) exercise every map label tier, and a
# layout-check stage asserts the map geometry itself: no two network
# panels may overlap, every node must land inside the fitted world, and
# the label tier must match the device count.
set -euo pipefail
cd "$(dirname "$0")/../.."
art="$PWD/.artifacts/feat_port_doctor"
mkdir -p "$art"

harness="$(mktemp -d "${TMPDIR:-/tmp}/pd-native-XXXXXX")"
weston_pid=""
cleanup() {
  if [[ -n "$weston_pid" ]]; then kill "$weston_pid" 2>/dev/null || true; wait "$weston_pid" 2>/dev/null || true; fi
  rm -rf "$harness"
}
trap cleanup EXIT
mkdir -p "$harness/deck" "$harness/check" "$harness/runtime" "$harness/state"
chmod 700 "$harness/runtime" "$harness/state"
cp ./*.qml ./*.js "$harness/deck/"
cat > "$harness/deck/port-doctor.py" <<'STUB'
#!/usr/bin/python3 -I
"""Fixture stand-in for the real scanner: canned payloads, no network.
All names and addresses are synthetic."""
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
        {"ip": "10.30.0.42", "hostname": "studio",
         "mac": "a4:b1:97:11:22:33", "macPrivate": False, "vendor": "Apple",
         "isSelf": False, "isGateway": False, "via": "unifi", "latencyMs": 3.8,
         "type": "desktop", "network": "Studio", "vlan": 10, "remoteNet": True,
         "ports": [{"port": 22, "proto": "tcp", "service": "ssh", "class": "remote"},
                   {"port": 11434, "proto": "tcp", "service": "ollama", "class": "dev"}]},
        {"ip": "10.30.90.20", "hostname": "echo-kitchen",
         "mac": "40:b4:cd:44:55:66", "macPrivate": False, "vendor": "Amazon",
         "isSelf": False, "isGateway": False, "via": "unifi", "latencyMs": None,
         "type": "iot", "network": "IoT", "vlan": 3, "remoteNet": True,
         "ports": []}
    ],
    "stats": {"targets": 254, "hostsUp": 8, "openPorts": 9,
              "scanMs": 4600, "discoveryMs": 1500, "controllerMs": 180,
              "deadlineHit": False}
}


def census(hosts, gateway_ip, self_ip, cidr):
    open_ports = sum(len(h["ports"]) for h in hosts)
    return {
        "version": 1, "mode": "lan", "scannedAt": "2026-09-17T12:00:00+00:00",
        "error": None, "profile": "standard",
        "identity": {"hostname": "dev-laptop", "model": "Fixture Laptop",
                     "manufacturer": "Fixture Co.", "label": "dev-laptop"},
        "controller": {"configured": True, "host": gateway_ip,
                       "site": "default", "clients": len(hosts), "error": None},
        "network": {"cidr": cidr, "ifname": "eth0",
                    "selfIp": self_ip, "gateway": gateway_ip,
                    "truncated": False, "passiveOnly": False, "note": ""},
        "hosts": hosts,
        "stats": {"targets": 254, "hostsUp": len(hosts), "openPorts": open_ports,
                  "scanMs": 9800, "discoveryMs": 2100, "controllerMs": 240,
                  "deadlineHit": False}
    }


def host(ip, name, kind, vendor, network, vlan, routed, ports,
         is_self=False, is_gateway=False):
    return {"ip": ip, "hostname": name,
            "mac": "02:11:22:" + ":".join(ip.split(".")[1:]),
            "macPrivate": vendor == "", "vendor": vendor,
            "isSelf": is_self, "isGateway": is_gateway,
            "via": "unifi" if routed else "scan",
            "latencyMs": None if routed else 2.4,
            "type": kind, "network": network, "vlan": vlan,
            "remoteNet": routed,
            "ports": [{"port": p, "proto": "tcp", "service": "svc",
                       "class": "infra"} for p in ports]}


def medium_lan():
    """A mid-size census that lands in the name-only label tier."""
    hosts = [
        host("10.30.10.1", "gw-core", "router", "Ubiquiti", "Home", 0,
             False, [53, 443], is_gateway=True),
        host("10.30.10.49", "dev-laptop", "laptop", "Dell", "Home", 0,
             False, [22], is_self=True),
    ]
    for ip, name, kind, vendor, ports in [
            ("10.30.10.21", "nas-01", "nas", "Synology", [445, 5000]),
            ("10.30.10.22", "pi-01", "raspberry-pi", "Raspberry Pi", [53]),
            ("10.30.10.23", "printer-01", "printer", "HP", [9100]),
            ("10.30.10.24", "tablet-01", "tablet", "Apple", []),
            ("10.30.10.25", "laptop-02", "laptop", "Apple", []),
            ("10.30.10.26", "phone-01", "phone", "Apple", [])]:
        hosts.append(host(ip, name, kind, vendor, "Home", 0, False, ports))
    for ip, name, kind, vendor, ports in [
            ("10.30.20.11", "studio-01", "desktop", "Apple", [22, 8000]),
            ("10.30.20.12", "mac-01", "desktop", "Apple", [22]),
            ("10.30.20.13", "win-01", "desktop", "", [3389]),
            ("10.30.20.14", "cam-studio", "camera", "Axis", [])]:
        hosts.append(host(ip, name, kind, vendor, "Studio", 10, True, ports))
    for ip, name, kind, vendor, ports in [
            ("10.30.30.21", "echo-01", "iot", "Amazon", []),
            ("10.30.30.22", "plug-01", "iot", "Tuya", []),
            ("10.30.30.23", "cam-01", "camera", "Wyze", []),
            ("10.30.30.24", "sensor-01", "iot", "", [])]:
        hosts.append(host(ip, name, kind, vendor, "IoT", 3, True, ports))
    return census(hosts, "10.30.10.1", "10.30.10.49", "10.30.10.0/24")


def large_lan():
    """A dense four-network census for the icon-only tier and the panel
    spacing math. Fully synthetic."""
    hosts = [
        host("10.20.10.1", "gw-core", "router", "Ubiquiti", "Home", 0,
             False, [53, 443], is_gateway=True),
        host("10.20.10.49", "dev-laptop", "laptop", "Dell", "Home", 0,
             False, [22], is_self=True),
    ]
    local = [
        ("10.20.10.21", "nas-01", "nas", "Synology", [22, 445]),
        ("10.20.10.22", "desktop-01", "desktop", "Dell", [3389]),
        ("10.20.10.23", "pi-01", "raspberry-pi", "Raspberry Pi", [22, 80]),
        ("10.20.10.24", "laptop-02", "laptop", "Apple", []),
        ("10.20.10.25", "tablet-01", "tablet", "Apple", []),
        ("10.20.10.26", "phone-02", "phone", "Apple", []),
        ("10.20.10.27", "watch-01", "iot", "Apple", []),
        ("10.20.10.28", "cam-doorbell", "camera", "Ring", []),
        ("10.20.10.29", "printer-01", "printer", "HP", [9100]),
        ("10.20.10.30", "tv-01", "tv", "LG", []),
    ]
    servers = [
        ("10.20.20.11", "ci-01", "server", "", [22]),
        ("10.20.20.12", "ci-02", "server", "", [22]),
        ("10.20.20.13", "ci-03", "server", "", [22]),
        ("10.20.20.14", "build-01", "server", "", [22]),
        ("10.20.20.15", "win-ci-01", "desktop", "", [3389]),
        ("10.20.20.16", "win-ci-02", "desktop", "", [3389]),
        ("10.20.20.17", "mac-ci-01", "desktop", "Apple", [22]),
        ("10.20.20.18", "util-01", "server", "", []),
        ("10.20.20.19", "proxy-01", "server", "", [443]),
    ]
    iot = [
        ("10.20.30.21", "cam-01", "camera", "Ring", []),
        ("10.20.30.22", "cam-02", "camera", "Ring", [554]),
        ("10.20.30.23", "cam-03", "camera", "Ring", []),
        ("10.20.30.24", "cam-04", "camera", "Wyze", []),
        ("10.20.30.25", "cam-05", "camera", "Wyze", []),
        ("10.20.30.26", "cam-06", "camera", "Blink", []),
        ("10.20.30.31", "echo-01", "iot", "Amazon", []),
        ("10.20.30.32", "echo-02", "iot", "Amazon", []),
        ("10.20.30.33", "echo-03", "iot", "Amazon", []),
        ("10.20.30.41", "plug-01", "iot", "Tuya", []),
        ("10.20.30.42", "plug-02", "iot", "Tuya", []),
        ("10.20.30.43", "plug-03", "iot", "Tuya", []),
        ("10.20.30.51", "sensor-01", "iot", "", []),
        ("10.20.30.52", "sensor-02", "iot", "", []),
        ("10.20.30.53", "sensor-03", "iot", "", []),
        ("10.20.30.61", "vacuum-01", "iot", "Roborock", []),
        ("10.20.30.62", "thermo-01", "iot", "Google", []),
        ("10.20.30.63", "wled-01", "iot", "", [80]),
    ]
    vpn = [
        ("192.168.9.2", "laptop-remote", "laptop", "Apple", []),
        ("192.168.9.3", "phone-remote", "phone", "Apple", []),
    ]
    for ip, name, kind, vendor, ports in local:
        hosts.append(host(ip, name, kind, vendor, "Home", 0, False, ports))
    for ip, name, kind, vendor, ports in servers:
        hosts.append(host(ip, name, kind, vendor, "Servers", 1, True, ports))
    for ip, name, kind, vendor, ports in iot:
        hosts.append(host(ip, name, kind, vendor, "IoT", 3, True, ports))
    for ip, name, kind, vendor, ports in vpn:
        hosts.append(host(ip, name, kind, vendor, "VPN", 9, True, ports))
    return census(hosts, "10.20.10.1", "10.20.10.49", "10.20.10.0/24")


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
    size = os.environ.get("PD_FIXTURE", "small")
    payload = {"small": LAN, "medium": medium_lan, "large": large_lan}[size]
    payload = payload() if callable(payload) else payload
    print(json.dumps(payload, separators=(",", ":")))
    # Harness marker: proves which census actually rendered.
    print("fixture-hosts=%d" % len(payload["hosts"]), file=sys.stderr)
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
  Timer { interval: 1900; running: true; onTriggered: plugin.setPage("services") }
  Timer { interval: 2300; running: true; onTriggered: plugin.setPage("machine") }
  Timer { interval: 2700; running: true; onTriggered: plugin.setPage("watch") }
  Timer { interval: 3100; running: true; onTriggered: plugin.setPage("history") }
  Timer { interval: 3500; running: true; onTriggered: plugin.setPage("settings") }
  Timer { interval: 3900; running: true; onTriggered: plugin.setPage("topology") }
  Timer { interval: 4300; running: true; onTriggered: plugin.close() }
  Timer { interval: 4600; running: true; onTriggered: Qt.quit() }
}
QML

cat > "$harness/check-shell.qml" <<'QML'
import QtQuick
import Quickshell
import "deck" as Deck
import "fixture.js" as Fixture

ShellRoot {
  Deck.TopologyView {
    id: tv
    width: 1240
    height: 560
    hosts: Fixture.lan.hosts
  }

  Timer {
    interval: 900
    running: true
    onTriggered: {
      var problems = []
      var panels = tv.clusterPanels
      for (var i = 0; i < panels.length; i++) {
        for (var j = i + 1; j < panels.length; j++) {
          var a = panels[i], b = panels[j]
          if (a.x < b.x + b.w && b.x < a.x + a.w
              && a.y < b.y + b.h && b.y < a.y + a.h)
            problems.push("panels overlap: " + a.name + "/" + b.name)
        }
      }
      var ns = tv.nodePlacements
      for (i = 0; i < ns.length; i++) {
        var nd = ns[i]
        if (nd.x < 0 || nd.y < 0 || nd.x > tv.worldW || nd.y > tv.worldH)
          problems.push("node out of world: " + String(nd.host.ip))
        if (!nd.big && nd.labels !== Fixture.expectLabels)
          problems.push("label tier " + nd.labels + " on " + String(nd.host.ip))
      }
      if (!(tv.worldScale > 0 && tv.worldScale <= 1))
        problems.push("worldScale out of range: " + tv.worldScale)
      if (tv.nodePlacements.length !== Fixture.lan.hosts.length)
        problems.push("placements " + tv.nodePlacements.length
                      + " != hosts " + Fixture.lan.hosts.length)
      console.log("LAYOUT-CHECK " + (problems.length === 0
        ? "PASS" : "FAIL " + problems.join("; ")))
      Qt.quit()
    }
  }
  Timer { interval: 12000; running: true; onTriggered: Qt.quit() }
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
  local fixture="$1" log="$2" expect_hosts="$3"
  PD_FIXTURE="$fixture" QT_QPA_PLATFORM=wayland python3 tests/ui/native-run.py "$harness" "$log"
  cat "$log"
  grep -q 'Configuration Loaded' "$log"
  grep -q "fixture-hosts=$expect_hosts" "$log"
  if grep -Eq 'ERROR|ReferenceError|TypeError|is not a type|Cannot assign|Required property' "$log"; then
    echo "QML errors in $fixture pass" >&2
    exit 1
  fi
}

check_layout() {
  local fixture="$1" expect_labels="$2"
  rm -rf "$harness/check"
  mkdir -p "$harness/check"
  cp -r "$harness/deck" "$harness/check/deck"
  cp -r "$harness/Ui" "$harness/Commons" "$harness/check/"
  cp "$harness/check-shell.qml" "$harness/check/shell.qml"
  PD_FIXTURE="$fixture" python3 "$harness/deck/port-doctor.py" lan \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
for h in d["hosts"]:
    h["online"] = True
print(json.dumps(d))' > "$harness/lan.json"
  { printf 'var lan = '; cat "$harness/lan.json"; printf ';\nvar expectLabels = %s;\n' "$expect_labels"; } \
      > "$harness/check/fixture.js"
  QT_QPA_PLATFORM=wayland quickshell -p "$harness/check" --no-color \
    > "$art/layout-check-$fixture.log" 2>&1 || true
  grep -q "LAYOUT-CHECK PASS" "$art/layout-check-$fixture.log" \
    || { cat "$art/layout-check-$fixture.log"; exit 1; }
  echo "layout-check $fixture: PASS"
}

run_pass small "$art/native-parse.log" 8
run_pass medium "$art/native-parse-medium.log" 16
run_pass large "$art/native-parse-large.log" 41

check_layout small 2
check_layout medium 1
check_layout large 0
