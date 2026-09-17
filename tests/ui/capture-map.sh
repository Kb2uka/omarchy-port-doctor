#!/usr/bin/env bash
# Render the network map with the dense PD_FIXTURE=large census under a
# headless Weston compositor and save a capture via QML grabToImage.
# Purely a capture tool: the scanner is the fixture stub, so no network
# traffic. Usage: tests/ui/capture-map.sh <output.png>
set -euo pipefail
cd "$(dirname "$0")/../.."
art="$PWD/.artifacts/feat_port_doctor"
mkdir -p "$art"
out="${1:-$art/map-large.png}"
fixture="${2:-large}"

harness="$(mktemp -d /tmp/pd-capture-XXXXXX)"
weston_pid=""
qs_pid=""
cleanup() {
  if [[ -n "$qs_pid" ]]; then kill "$qs_pid" 2>/dev/null || true; wait "$qs_pid" 2>/dev/null || true; fi
  if [[ -n "$weston_pid" ]]; then kill "$weston_pid" 2>/dev/null || true; wait "$weston_pid" 2>/dev/null || true; fi
  rm -rf "$harness"
}
trap cleanup EXIT
mkdir -p "$harness/deck" "$harness/runtime" "$harness/state"
chmod 700 "$harness/runtime" "$harness/state"
cp ./*.qml ./*.js "$harness/deck/"

# Reuse the fixture stub defined by the smoke harness so both stay in sync,
# then materialize the large census as a JS module the harness can bind.
awk '/^cat > .*port-doctor.py/ {on=1; next} on && /^STUB$/ {exit} on' tests/ui/native-parse.sh \
  > "$harness/deck/port-doctor.py"
grep -q 'large_lan' "$harness/deck/port-doctor.py"
PD_FIXTURE="$fixture" python3 "$harness/deck/port-doctor.py" lan \
  | python3 -c 'import json, sys
d = json.load(sys.stdin)
for h in d["hosts"]:
    h["online"] = True
print(json.dumps(d))' > "$harness/lan.json"
{ printf 'var lan = '; cat "$harness/lan.json"; printf ';\n'; } > "$harness/deck/fixture.js"

cp -r /usr/share/omarchy/shell/Ui /usr/share/omarchy/shell/Commons "$harness/"
cat > "$harness/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "deck" as Deck
import "deck/fixture.js" as Fixture

ShellRoot {
  FloatingWindow {
    id: win
    visible: true
    implicitWidth: 1440
    implicitHeight: 920
    color: "#0b0f14"

    Deck.AppView {
      id: app
      anchors.fill: parent
      hosts: Fixture.lan.hosts
      network: Fixture.lan.network
      identity: Fixture.lan.identity
      controller: Fixture.lan.controller
      scannedAt: Fixture.lan.scannedAt
      scanning: false
      page: "topology"
    }
  }

  Timer {
    interval: 1600
    running: true
    onTriggered: app.grabToImage(function(result) {
      result.saveToFile("__OUT__")
      Qt.quit()
    })
  }
  Timer { interval: 9000; running: true; onTriggered: Qt.quit() }
}
QML
sed -i "s|__OUT__|$out|" "$harness/shell.qml"

export XDG_RUNTIME_DIR="$harness/runtime"
export XDG_STATE_HOME="$harness/state"
export WAYLAND_DISPLAY=pd-capture

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
  --socket="$WAYLAND_DISPLAY" --idle-time=0 --no-config > "$art/weston-capture.log" 2>&1 &
weston_pid=$!
for attempt in {1..50}; do
  [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break
  kill -0 "$weston_pid" 2>/dev/null || { cat "$art/weston-capture.log"; exit 1; }
  sleep 0.1
done

QT_QPA_PLATFORM=wayland quickshell -p "$harness" --no-color > "$art/capture.log" 2>&1 &
qs_pid=$!
wait "$qs_pid" 2>/dev/null || true
qs_pid=""
grep -q 'Configuration Loaded' "$art/capture.log"
if grep -Eq 'ERROR|ReferenceError|TypeError|is not a type|Cannot assign|Required property' "$art/capture.log"; then exit 1; fi
[[ -s "$out" ]]
echo "captured: $out"
