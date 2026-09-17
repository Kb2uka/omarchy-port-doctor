"""Parser tests for iproute2 output and the scan-window math."""

import unittest

from port_doctor import net


ADDR_SHOW = [
    {"ifindex": 1, "ifname": "lo", "flags": ["LOOPBACK", "UP"],
     "addr_info": [{"family": "inet", "local": "127.0.0.1", "prefixlen": 8}]},
    {"ifindex": 2, "ifname": "wlan0", "flags": ["BROADCAST", "MULTICAST", "UP"],
     "addr_info": [{"family": "inet", "local": "10.70.120.50", "prefixlen": 24},
                   {"family": "inet6", "local": "fe80::1", "prefixlen": 64}]},
    {"ifindex": 3, "ifname": "docker0", "flags": ["BROADCAST", "MULTICAST"],
     "addr_info": [{"family": "inet", "local": "172.17.0.1", "prefixlen": 16}]},
]

ROUTE_DEFAULT = [
    {"dst": "default", "gateway": "10.70.120.1", "dev": "wlan0"},
    {"dst": "default", "dev": "wlan0"},  # no gateway: skipped
    "junk",
]

NEIGH_SHOW = [
    {"dst": "10.70.120.1", "dev": "wlan0", "lladdr": "F0:9F:C2:11:22:33",
     "state": ["REACHABLE"]},
    {"dst": "10.70.120.77", "dev": "wlan0", "state": ["STALE"]},
    {"dst": "not-an-ip", "dev": "wlan0", "lladdr": "aa:bb:cc:dd:ee:ff",
     "state": ["FAILED"]},
    {"dst": "10.70.120.99", "dev": "wlan0", "lladdr": "AA:BB:CC:DD:EE:FF",
     "state": ["DELAY"]},
]


class InterfaceTests(unittest.TestCase):
    def test_parse_interfaces(self):
        original = net._ip_json
        net._ip_json = lambda *args: ADDR_SHOW
        try:
            ifaces = net.interfaces()
        finally:
            net._ip_json = original
        self.assertEqual(len(ifaces), 1)
        self.assertEqual(ifaces[0]["ifname"], "wlan0")
        self.assertEqual(ifaces[0]["addrs"],
                         [{"local": "10.70.120.50", "prefixlen": 24}])

    def test_gateways_and_neighbors(self):
        original = net._ip_json
        net._ip_json = lambda *args: (ROUTE_DEFAULT if "route" in args
                                      else NEIGH_SHOW)
        try:
            gateways = net.default_gateways()
            neigh = net.neighbors()
        finally:
            net._ip_json = original
        self.assertEqual(gateways, [{"gateway": "10.70.120.1", "dev": "wlan0"}])
        self.assertEqual(len(neigh), 3)
        self.assertEqual(neigh["10.70.120.1"]["mac"], "f0:9f:c2:11:22:33")
        self.assertEqual(neigh["10.70.120.77"]["mac"], "")
        self.assertEqual(neigh["10.70.120.99"]["state"], "DELAY")


class ScannableTests(unittest.TestCase):
    def test_private_ranges(self):
        for ip in ("10.0.0.1", "172.16.0.1", "192.168.1.1",
                   "169.254.1.1", "100.64.0.1"):
            self.assertTrue(net.scannable(ip), ip)

    def test_public_and_special_ranges(self):
        for ip in ("8.8.8.8", "1.1.1.1", "127.0.0.1", "0.0.0.0",
                   "224.0.0.1", "240.0.0.1", "255.255.255.255",
                   "192.0.2.1", "203.0.113.10", "198.51.100.7",
                   "not-an-ip", ""):
            self.assertFalse(net.scannable(ip), ip)


class WindowTests(unittest.TestCase):
    def test_slash24_keeps_hosts(self):
        cidr, hosts, truncated = net.network_window("10.70.120.50", 24)
        self.assertEqual(cidr, "10.70.120.0/24")
        self.assertEqual(len(hosts), 254)
        self.assertFalse(truncated)
        self.assertNotIn("10.70.120.0", hosts)
        self.assertNotIn("10.70.120.255", hosts)

    def test_wide_prefix_collapses_to_slash24(self):
        cidr, hosts, truncated = net.network_window("10.70.120.50", 16)
        self.assertEqual(cidr, "10.70.120.0/24")
        self.assertEqual(len(hosts), 254)
        self.assertTrue(truncated)

    def test_tiny_prefix_honored(self):
        cidr, hosts, truncated = net.network_window("192.168.1.2", 30)
        self.assertEqual(cidr, "192.168.1.0/30")
        self.assertEqual(hosts, ["192.168.1.1", "192.168.1.2"])
        self.assertFalse(truncated)

    def test_host_route_scans_itself(self):
        cidr, hosts, truncated = net.network_window("192.168.1.2", 32)
        self.assertEqual(hosts, ["192.168.1.2"])


if __name__ == "__main__":
    unittest.main()
