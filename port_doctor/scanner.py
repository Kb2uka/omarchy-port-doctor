"""Compose Port Doctor payloads and the command line.

Two subcommands, both read-only and bounded:
  lan      discover hosts on the local subnet and probe their TCP ports
  machine  this machine's listening sockets and live connections

The panel calls each on its own clock: machine data is cheap (proc reads),
the LAN scan is not, so they refresh on different intervals.
"""

import datetime
import json
import sys

from . import identity, machine, net, scan, services


def _now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def lan_payload(quick=False):
    payload = {"version": 1, "mode": "lan", "scannedAt": _now(), "error": None}
    try:
        payload["identity"] = identity.computer_identity()
        ports = services.DISCOVERY_PORTS if quick else None
        payload.update(scan.scan_lan(port_list=ports))
        # The resolver rarely names this machine's own address; the
        # identity block always can.
        self_ip = payload.get("network", {}).get("selfIp", "")
        hostname = payload["identity"]["hostname"]
        if self_ip and hostname:
            for host in payload.get("hosts", []):
                if host.get("ip") == self_ip and not host.get("hostname"):
                    host["hostname"] = hostname
    except Exception as error:  # the panel must never see a stack trace
        payload["error"] = str(error)[:200]
        payload.setdefault("identity", {"hostname": "", "model": "",
                                        "manufacturer": "",
                                        "label": "This machine"})
        payload["network"] = {"cidr": "", "ifname": "", "selfIp": "",
                              "gateway": "", "truncated": False,
                              "passiveOnly": True, "note": "scan failed"}
        payload["controller"] = {"configured": False, "host": "", "site": "",
                                 "clients": 0, "error": None}
        payload["hosts"] = []
        payload["stats"] = {"targets": 0, "hostsUp": 0, "openPorts": 0,
                            "scanMs": 0, "discoveryMs": 0, "controllerMs": 0,
                            "deadlineHit": False}
    payload["profile"] = "quick" if quick else "standard"
    return payload


def machine_payload():
    payload = {"version": 1, "mode": "machine", "scannedAt": _now(),
               "error": None}
    try:
        payload["identity"] = identity.computer_identity()
        # Classify peers against every scannable subnet this machine sits on;
        # pure address math, no probe traffic.
        cidrs = []
        for iface in net.interfaces():
            for addr in iface["addrs"]:
                if net.scannable(addr["local"]):
                    cidr, _, _ = net.network_window(addr["local"],
                                                    addr["prefixlen"])
                    cidrs.append(cidr)
        payload.update(machine.machine_snapshot(lan_cidrs=tuple(cidrs)))
    except Exception as error:
        payload["error"] = str(error)[:200]
        payload.setdefault("identity", {"hostname": "", "model": "",
                                        "manufacturer": "",
                                        "label": "This machine"})
        payload["hostname"] = ""
        payload["listeners"] = []
        payload["connections"] = []
        payload["stats"] = {"listeners": 0, "connections": 0,
                            "truncatedListeners": 0, "truncatedConnections": 0}
    return payload


_USAGE = "usage: port-doctor.py {lan|lan-quick|machine}"


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) != 1 or argv[0] not in ("lan", "lan-quick", "machine"):
        print(_USAGE, file=sys.stderr)
        return 2
    if argv[0] == "machine":
        payload = machine_payload()
    else:
        payload = lan_payload(quick=argv[0] == "lan-quick")
    print(json.dumps(payload, separators=(",", ":")))
    return 0
