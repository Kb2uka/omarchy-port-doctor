"""This-machine socket parsing against a fabricated /proc tree."""

import json
import os
import tempfile
import unittest
from pathlib import Path

from port_doctor import machine, scanner


TCP_FIXTURE = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11111 1 0000000000000000 100 0 0 10 0
   1: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22222 1 0000000000000000 100 0 0 10 0
   2: 3278460A:C822 0178460A:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 33333 1 0000000000000000 100 0 0 10 0
   3: 3278460A:8C3A 01010101:0035 01 00000000:00000000 00:00000000 00000000  1000        0 44444 1 0000000000000000 100 0 0 10 0
"""

TCP6_FIXTURE = """  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 55555 1 0000000000000000 100 0 0 10 0
"""

UDP_FIXTURE = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0044 00000000:0000 07 00000000:00000000 00:00000000 00000000  1000        0 66666 1 0000000000000000 100 0 0 10 0
"""


def make_proc(root):
    net_dir = Path(root) / "net"
    net_dir.mkdir(parents=True)
    (net_dir / "tcp").write_text(TCP_FIXTURE)
    (net_dir / "tcp6").write_text(TCP6_FIXTURE)
    (net_dir / "udp").write_text(UDP_FIXTURE)
    (net_dir / "udp6").write_text("")
    pid_dir = Path(root) / "4321"
    (pid_dir / "fd").mkdir(parents=True)
    (pid_dir / "comm").write_text("myservice\n")
    os.symlink("socket:[33333]", pid_dir / "fd" / "3")
    os.symlink("socket:[11111]", pid_dir / "fd" / "4")
    os.symlink("/dev/null", pid_dir / "fd" / "5")


class MachineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        make_proc(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self):
        return machine.machine_snapshot(
            proc_root=self.tmp.name,
            resolver=lambda ips: {"10.70.120.1": "gateway.local"},
            lan_cidrs=("10.70.120.0/24",))

    def test_listeners_and_scope(self):
        snap = self.snapshot()
        listeners = {(l["port"], l["proto"]): l for l in snap["listeners"]}
        self.assertEqual(len(snap["listeners"]), 4)

        ssh = listeners[(22, "tcp")]
        self.assertEqual(ssh["scope"], "all interfaces")
        self.assertEqual(ssh["process"], "myservice")
        self.assertEqual(ssh["pid"], 4321)
        self.assertEqual(ssh["service"], "ssh")
        self.assertEqual(ssh["class"], "remote")

        ipp = listeners[(631, "tcp")]
        self.assertEqual(ipp["scope"], "loopback only")
        self.assertEqual(ipp["process"], "")  # inode 22222 owned by nobody here
        self.assertIsNone(ipp["pid"])

        v6 = listeners[(8080, "tcp6")]
        self.assertEqual(v6["bind"], "::1")
        self.assertEqual(v6["scope"], "loopback only")

        dhcp = listeners[(68, "udp")]
        self.assertEqual(dhcp["scope"], "all interfaces")
        self.assertEqual(dhcp["service"], "dhcp")

    def test_machine_payload_classifies_against_local_subnets(self):
        """The CLI path must derive lan_cidrs itself (an earlier version
        passed an empty list, so no peer could ever classify as lan)."""
        captured = {}

        def fake_snapshot(**kwargs):
            captured.update(kwargs)
            return {"hostname": "h", "listeners": [], "connections": [],
                    "stats": {"listeners": 0, "connections": 0,
                              "truncatedListeners": 0,
                              "truncatedConnections": 0}}

        original_interfaces = scanner.net.interfaces
        original_snapshot = scanner.machine.machine_snapshot
        scanner.net.interfaces = lambda: [
            {"ifname": "wlan0",
             "addrs": [{"local": "10.70.120.50", "prefixlen": 24}]},
            {"ifname": "wan0",
             "addrs": [{"local": "203.0.113.9", "prefixlen": 24}]},
        ]
        scanner.machine.machine_snapshot = fake_snapshot
        try:
            payload = scanner.machine_payload()
        finally:
            scanner.net.interfaces = original_interfaces
            scanner.machine.machine_snapshot = original_snapshot
        self.assertIsNone(payload["error"])
        self.assertEqual(captured["lan_cidrs"], ("10.70.120.0/24",))

    def test_connections_and_kinds(self):
        snap = self.snapshot()
        self.assertEqual(len(snap["connections"]), 2)
        by_remote = {c["remoteIp"]: c for c in snap["connections"]}

        lan = by_remote["10.70.120.1"]
        self.assertEqual(lan["remoteKind"], "lan")
        self.assertEqual(lan["remotePort"], 443)
        self.assertEqual(lan["state"], "established")
        self.assertEqual(lan["process"], "myservice")
        self.assertEqual(lan["remoteName"], "gateway.local")

        dns = by_remote["1.1.1.1"]
        self.assertEqual(dns["remoteKind"], "internet")
        self.assertEqual(dns["process"], "")
        self.assertEqual(dns["remoteName"], "")

        # LAN peers sort ahead of internet peers.
        self.assertEqual(snap["connections"][0]["remoteKind"], "lan")

    def test_empty_proc_is_an_empty_snapshot(self):
        with tempfile.TemporaryDirectory() as empty:
            snap = machine.machine_snapshot(proc_root=empty, resolver=lambda ips: {})
        self.assertEqual(snap["listeners"], [])
        self.assertEqual(snap["connections"], [])

    def test_cli_machine_smoke(self):
        import contextlib
        import io

        real_snapshot = machine.machine_snapshot

        def no_dns_snapshot(**kwargs):
            kwargs["resolver"] = lambda ips: {}
            return real_snapshot(**kwargs)

        machine.machine_snapshot = no_dns_snapshot
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = scanner.main(["machine"])
        finally:
            machine.machine_snapshot = real_snapshot
        self.assertEqual(code, 0)
        payload = json.loads(out.getvalue())
        self.assertEqual(payload["mode"], "machine")
        self.assertIn("listeners", payload)
        self.assertIn("connections", payload)
        self.assertIsNone(payload["error"])

    def test_cli_rejects_unknown_modes(self):
        self.assertEqual(scanner.main(["bogus"]), 2)
        self.assertEqual(scanner.main([]), 2)
        self.assertEqual(scanner.main(["lan", "extra"]), 2)

    def test_cli_accepts_profiles(self):
        import contextlib
        import io

        port_lists = []

        def fake_lan(**kwargs):
            port_lists.append(kwargs.get("port_list"))
            return {"network": {}, "hosts": [], "stats": {}}

        original = scanner.scan.scan_lan
        scanner.scan.scan_lan = fake_lan
        try:
            for mode in ("lan", "lan-quick"):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(scanner.main([mode]), 0)
                self.assertEqual(json.loads(out.getvalue())["profile"],
                                 "quick" if mode == "lan-quick" else "standard")
        finally:
            scanner.scan.scan_lan = original
        from port_doctor import services
        self.assertEqual(port_lists, [None, services.DISCOVERY_PORTS])


if __name__ == "__main__":
    unittest.main()


class AddressFormTests(unittest.TestCase):
    def test_ipv4_mapped_ipv6_unwraps(self):
        self.assertEqual(machine._decode_ip("0000000000000000FFFF00000100000A", True),
                         "10.0.0.1")
        self.assertEqual(machine._decode_ip("00000000000000000000000001000000", True),
                         "::1")

    def test_cgnat_is_private_not_internet(self):
        self.assertEqual(machine._remote_kind("100.64.1.2", ()), "private")
        self.assertEqual(machine._remote_kind("8.8.8.8", ()), "internet")
