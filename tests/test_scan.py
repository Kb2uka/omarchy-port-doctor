"""LAN scan composition, with every network touch injected and fake."""

import time
import unittest

from port_doctor import net, scan


IFACES = [{"ifname": "wlan0",
           "addrs": [{"local": "10.70.120.50", "prefixlen": 24}]}]
GATEWAYS = [{"gateway": "10.70.120.1", "dev": "wlan0"}]
NEIGH = {
    "10.70.120.1": {"mac": "f0:9f:c2:11:22:33", "dev": "wlan0",
                    "state": "REACHABLE"},
    "10.70.120.99": {"mac": "b8:27:eb:aa:bb:cc", "dev": "wlan0",
                     "state": "STALE"},
    "10.70.120.200": {"mac": "", "dev": "wlan0", "state": "FAILED"},
}


def fake_scan(interfaces=IFACES, gateways=GATEWAYS, connector=None,
              resolver=None, deadline_s=9.0):
    original_neigh = net.neighbors
    net.neighbors = lambda: dict(NEIGH)
    try:
        return scan.scan_lan(
            interfaces=interfaces, gateways=gateways,
            connector=connector or (lambda ip, port, t: ("filtered", 0.0)),
            resolver=resolver or (lambda ips, deadline: {}),
            deadline_s=deadline_s)
    finally:
        net.neighbors = original_neigh


def by_ip(payload):
    return {h["ip"]: h for h in payload["hosts"]}


class ScanTests(unittest.TestCase):
    def test_hosts_ports_and_roles(self):
        def connector(ip, port, timeout):
            if ip == "10.70.120.1" and port == 53:
                return "open", 1.5
            if ip == "10.70.120.99" and port in (22, 32400):
                return "open", 3.0
            if ip == "10.70.120.99":
                return "closed", 2.0
            return "filtered", 0.0

        payload = fake_scan(connector=connector,
                            resolver=lambda ips, dl: {"10.70.120.99": "pi-hole"})
        netinfo = payload["network"]
        self.assertEqual(netinfo["cidr"], "10.70.120.0/24")
        self.assertEqual(netinfo["selfIp"], "10.70.120.50")
        self.assertEqual(netinfo["gateway"], "10.70.120.1")
        self.assertFalse(netinfo["passiveOnly"])

        hosts = by_ip(payload)
        # The FAILED neighbor never shows up.
        self.assertNotIn("10.70.120.200", hosts)
        # Self, gateway, and the answering Pi are present and sorted.
        ips = [h["ip"] for h in payload["hosts"]]
        self.assertEqual(ips, sorted(ips, key=lambda t: tuple(int(p) for p in t.split("."))))

        gateway = hosts["10.70.120.1"]
        self.assertTrue(gateway["isGateway"])
        self.assertEqual(gateway["vendor"], "Ubiquiti")
        self.assertEqual(gateway["ports"],
                         [{"port": 53, "proto": "tcp", "service": "dns",
                           "class": "infra"}])

        pi = hosts["10.70.120.99"]
        self.assertEqual(pi["hostname"], "pi-hole")
        self.assertEqual(pi["vendor"], "Raspberry Pi")
        self.assertEqual([p["port"] for p in pi["ports"]], [22, 32400])
        self.assertEqual(pi["ports"][1]["service"], "plex")
        self.assertEqual(pi["ports"][1]["class"], "media")
        self.assertEqual(pi["latencyMs"], 2.0)

        self.assertTrue(hosts["10.70.120.50"]["isSelf"])
        self.assertEqual(payload["stats"]["hostsUp"], 3)
        self.assertEqual(payload["stats"]["openPorts"], 3)

    def test_refused_still_marks_alive(self):
        def connector(ip, port, timeout):
            return ("closed", 1.0) if ip == "10.70.120.10" else ("filtered", 0.0)

        payload = fake_scan(connector=connector)
        hosts = by_ip(payload)
        self.assertIn("10.70.120.10", hosts)
        self.assertEqual(hosts["10.70.120.10"]["ports"], [])

    def test_no_private_interface_sends_no_probes(self):
        calls = []

        def connector(ip, port, timeout):
            calls.append((ip, port))
            return "open", 1.0

        public = [{"ifname": "eth0",
                   "addrs": [{"local": "203.0.113.10", "prefixlen": 24}]}]
        payload = fake_scan(interfaces=public, gateways=[], connector=connector)
        self.assertEqual(calls, [])
        self.assertTrue(payload["network"]["passiveOnly"])
        self.assertNotEqual(payload["network"]["note"], "")
        hosts = by_ip(payload)
        # Only non-FAILED scannable neighbors are reported.
        self.assertIn("10.70.120.1", hosts)
        self.assertIn("10.70.120.99", hosts)
        self.assertNotIn("10.70.120.200", hosts)

    def test_deadline_bounds_a_slow_network(self):
        def connector(ip, port, timeout):
            time.sleep(0.25)
            return "open", 250.0

        started = time.monotonic()
        payload = fake_scan(connector=connector, deadline_s=0.3)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 5.0)
        self.assertTrue(payload["stats"]["deadlineHit"])

    def test_gateways_seed_liveness(self):
        calls = []

        def connector(ip, port, timeout):
            calls.append(ip)
            return "filtered", 0.0

        payload = fake_scan(connector=connector)
        hosts = by_ip(payload)
        # Gateway was never probed in discovery (seeded alive) but was
        # scanned for ports, and it appears in the result regardless.
        self.assertIn("10.70.120.1", hosts)
        discovery_targets = set(calls)
        self.assertIn("10.70.120.10", discovery_targets)

    def test_discovery_answers_merge_and_are_not_reprobed(self):
        calls = []

        def connector(ip, port, timeout):
            calls.append((ip, port))
            if ip == "10.70.120.10" and port == 443:
                return "open", 1.0
            if ip == "10.70.120.10":
                return "closed", 2.0
            return "filtered", 0.0

        payload = fake_scan(connector=connector)
        hosts = by_ip(payload)
        self.assertIn("10.70.120.10", hosts)
        self.assertEqual([p["port"] for p in hosts["10.70.120.10"]["ports"]],
                         [443])
        self.assertEqual(hosts["10.70.120.10"]["latencyMs"], 1.0)
        # Every port answered during discovery (open or refused) is settled:
        # the full pass must not probe it again.
        self.assertEqual(calls.count(("10.70.120.10", 443)), 1)
        self.assertEqual(calls.count(("10.70.120.10", 22)), 1)


if __name__ == "__main__":
    unittest.main()
