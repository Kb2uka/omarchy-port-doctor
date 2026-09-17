"""LAN scan composition, with every network touch injected and fake."""

import time
import unittest

from port_doctor import net, scan, services


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

EMPTY_CENSUS = {"configured": False, "host": "", "site": "", "error": None,
                "clients": [], "networks": []}


def fake_scan(interfaces=IFACES, gateways=GATEWAYS, connector=None,
              resolver=None, deadline_s=9.0, controller=None):
    original_neigh = net.neighbors
    net.neighbors = lambda: dict(NEIGH)
    try:
        return scan.scan_lan(
            interfaces=interfaces, gateways=gateways,
            connector=connector or (lambda ip, port, t: ("filtered", 0.0)),
            resolver=resolver or (lambda ips, deadline: {}),
            deadline_s=deadline_s,
            controller=controller or (lambda timeout: dict(EMPTY_CENSUS)))
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

    def test_names_for_uses_the_real_lookup_path(self):
        """Regression: _names_for must actually collect resolver answers
        (an earlier inverted future/ip tuple silently dropped them all)."""
        calls = []

        def fake_gethostbyaddr(ip):
            calls.append(ip)
            if ip == "10.0.0.9":
                return ("pi-hole.lan.", [], [])
            if ip == "10.0.0.10":
                return ("x" * 80, [], [])  # over-long names are dropped
            raise OSError("no PTR")

        original = scan.socket.gethostbyaddr
        scan.socket.gethostbyaddr = fake_gethostbyaddr
        try:
            names = scan._names_for(["10.0.0.9", "10.0.0.10", "10.0.0.11"],
                                    time.monotonic() + 2.0)
        finally:
            scan.socket.gethostbyaddr = original
        self.assertEqual(sorted(calls), ["10.0.0.10", "10.0.0.11", "10.0.0.9"])
        self.assertEqual(names, {"10.0.0.9": "pi-hole.lan"})

    def test_unscannable_gateway_is_not_seeded(self):
        def connector(ip, port, timeout):
            return "filtered", 0.0

        payload = fake_scan(gateways=[{"gateway": "8.8.8.8", "dev": "wlan0"}],
                            connector=connector)
        hosts = by_ip(payload)
        self.assertNotIn("8.8.8.8", hosts)


if __name__ == "__main__":
    unittest.main()


class InterfaceChoiceTests(unittest.TestCase):
    def test_point_to_point_vpn_never_beats_the_lan(self):
        ifaces = [
            {"ifname": "wg0", "addrs": [{"local": "10.9.0.2", "prefixlen": 30}]},
            {"ifname": "wlan0", "addrs": [{"local": "10.70.120.50", "prefixlen": 24}]},
        ]
        gws = [{"gateway": "10.9.0.1", "dev": "wg0"}]
        payload = fake_scan(interfaces=ifaces, gateways=gws)
        self.assertEqual(payload["network"]["ifname"], "wlan0")
        self.assertEqual(payload["network"]["cidr"], "10.70.120.0/24")

    def test_link_local_only_is_passive(self):
        calls = []

        def connector(ip, port, timeout):
            calls.append((ip, port))
            return "open", 1.0

        ifaces = [{"ifname": "eth0",
                   "addrs": [{"local": "169.254.1.5", "prefixlen": 16}]}]
        payload = fake_scan(interfaces=ifaces, gateways=[], connector=connector)
        self.assertEqual(calls, [])
        self.assertTrue(payload["network"]["passiveOnly"])


CENSUS = {
    "configured": True, "host": "10.70.120.1", "site": "default",
    "error": None,
    "clients": [
        {"ip": "10.70.0.42", "mac": "a4:b1:97:11:22:33", "name": "studio",
         "network": "Default", "vlan": 0},
        {"ip": "10.70.90.20", "mac": "40:b4:cd:44:55:66", "name": "echo-k",
         "network": "IoT", "vlan": 3},
        # On the local subnet but silent to probes (sleeping, firewalled).
        {"ip": "10.70.120.77", "mac": "b8:27:eb:cc:dd:ee",
         "name": "sleepy-pi", "network": "SHACK", "vlan": 4},
    ],
    "networks": [
        {"name": "Default", "vlan": 0, "subnet": "10.70.0.0/24"},
        {"name": "IoT", "vlan": 3, "subnet": "10.70.90.0/24"},
        {"name": "SHACK", "vlan": 4, "subnet": "10.70.120.0/24"},
    ],
}


def census_controller(timeout=0):
    return dict(CENSUS)


class ControllerMergeTests(unittest.TestCase):
    def test_remote_hosts_join_with_ports_names_and_labels(self):
        def connector(ip, port, timeout):
            if ip == "10.70.0.42" and port == 22:
                return "open", 1.5
            if ip == "10.70.0.42":
                return "closed", 2.0
            return "filtered", 0.0

        payload = fake_scan(connector=connector, controller=census_controller)
        hosts = by_ip(payload)
        studio = hosts["10.70.0.42"]
        self.assertEqual(studio["via"], "unifi")
        self.assertTrue(studio["remoteNet"])
        self.assertEqual(studio["network"], "Default")
        self.assertEqual(studio["vlan"], 0)
        # Controller name filled the gap the resolver left.
        self.assertEqual(studio["hostname"], "studio")
        # Cross-VLAN MACs come from the controller record, not the
        # neighbor table.
        self.assertEqual(studio["mac"], "a4:b1:97:11:22:33")
        self.assertEqual(studio["vendor"], "Apple")
        self.assertEqual([p["port"] for p in studio["ports"]], [22])
        self.assertEqual(studio["latencyMs"], 1.5)

        controller = payload["controller"]
        self.assertTrue(controller["configured"])
        self.assertEqual(controller["clients"], 3)
        self.assertIsNone(controller["error"])
        self.assertIn("controllerMs", payload["stats"])

    def test_filtered_remote_stays_presence_only(self):
        calls = []

        def connector(ip, port, timeout):
            calls.append((ip, port))
            return "filtered", 0.0

        payload = fake_scan(connector=connector, controller=census_controller)
        hosts = by_ip(payload)
        echo = hosts["10.70.90.20"]
        self.assertEqual(echo["via"], "unifi")
        self.assertEqual(echo["ports"], [])
        self.assertEqual(echo["network"], "IoT")
        # Presence comes from the controller, so only the discovery set is
        # probed: an isolated network cannot burn the deadline on a full
        # table of timeouts.
        probed = {port for ip, port in calls if ip == "10.70.90.20"}
        self.assertEqual(probed, set(services.DISCOVERY_PORTS))

    def test_controller_vouches_for_a_sleeping_local(self):
        calls = []

        def connector(ip, port, timeout):
            calls.append((ip, port))
            return "filtered", 0.0

        payload = fake_scan(connector=connector, controller=census_controller)
        hosts = by_ip(payload)
        sleepy = hosts["10.70.120.77"]
        self.assertEqual(sleepy["via"], "unifi")
        self.assertFalse(sleepy["remoteNet"])
        self.assertEqual(sleepy["network"], "SHACK")
        # A local-subnet host is worth the full table just like a
        # neighbor-seeded one.
        self.assertIn(("10.70.120.77", 32400), calls)

    def test_local_hosts_get_network_labels_by_subnet(self):
        payload = fake_scan(controller=census_controller)
        hosts = by_ip(payload)
        for ip in ("10.70.120.50", "10.70.120.1", "10.70.120.99"):
            self.assertEqual(hosts[ip]["network"], "SHACK", ip)
            self.assertEqual(hosts[ip]["vlan"], 4, ip)
            self.assertFalse(hosts[ip]["remoteNet"], ip)

    def test_passive_mode_never_calls_the_controller(self):
        calls = []

        def controller(timeout=0):
            calls.append(timeout)
            return dict(CENSUS)

        public = [{"ifname": "eth0",
                   "addrs": [{"local": "203.0.113.10", "prefixlen": 24}]}]
        payload = fake_scan(interfaces=public, gateways=[],
                            controller=controller)
        self.assertEqual(calls, [])
        self.assertFalse(payload["controller"]["configured"])
        self.assertTrue(payload["network"]["passiveOnly"])

    def test_controller_failure_does_not_break_the_scan(self):
        def controller(timeout=0):
            raise RuntimeError("boom")

        payload = fake_scan(controller=controller)
        self.assertEqual(payload["controller"]["error"], "boom")
        hosts = by_ip(payload)
        self.assertIn("10.70.120.99", hosts)  # local results intact

    def test_remote_host_cap(self):
        clients = [{"ip": f"10.99.{i // 250}.{(i % 250) + 1}",
                    "mac": "", "name": f"h{i}", "network": "Big", "vlan": 9}
                   for i in range(200)]
        census = dict(CENSUS)
        census["clients"] = clients

        payload = fake_scan(controller=lambda timeout: census)
        remotes = [h for h in payload["hosts"] if h["remoteNet"]]
        self.assertEqual(len(remotes), scan.MAX_REMOTE_HOSTS)
        self.assertEqual(payload["controller"]["clients"], 200)

    def test_slow_controller_is_abandoned_at_its_budget(self):
        def controller(timeout=0):
            time.sleep(5)
            return dict(CENSUS)

        started = time.monotonic()
        # deadline 8s -> controller budget 1s; the scan must not wait 5.
        payload = fake_scan(controller=controller, deadline_s=8.0)
        self.assertLess(time.monotonic() - started, 4.0)
        self.assertIn("budget", payload["controller"]["error"])
        hosts = by_ip(payload)
        self.assertIn("10.70.120.99", hosts)  # local results intact

    def test_malformed_controller_mac_cannot_kill_the_scan(self):
        census = dict(CENSUS)
        census["clients"] = [
            {"ip": "10.70.0.42", "mac": "zz:zz:zz:zz:zz:zz",
             "name": "studio", "network": "Default", "vlan": 0},
        ]
        payload = fake_scan(controller=lambda timeout: census)
        hosts = by_ip(payload)
        # The scan survives and renders the row; the garbage MAC parses as
        # not-private and vendors nothing.
        self.assertIn("10.70.0.42", hosts)
        self.assertEqual(hosts["10.70.0.42"]["vendor"], "")
        self.assertFalse(hosts["10.70.0.42"]["macPrivate"])

    def test_falsy_controller_return_means_not_configured(self):
        payload = fake_scan(controller=lambda timeout: None)
        self.assertFalse(payload["controller"]["configured"])
        self.assertIsNone(payload["controller"]["error"])

    def test_thread_creation_failure_does_not_break_the_scan(self):
        class ExplodingThread:
            def __init__(self, *args, **kwargs):
                raise RuntimeError("can't start new thread")

        class FakeThreading:
            Thread = ExplodingThread

        original = scan.threading
        scan.threading = FakeThreading
        try:
            payload = fake_scan(controller=census_controller)
        finally:
            scan.threading = original
        self.assertIn("thread", payload["controller"]["error"])
        self.assertIn("10.70.120.99", by_ip(payload))
