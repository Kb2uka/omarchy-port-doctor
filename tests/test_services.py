"""Port table sanity: the scan surface is fixed, known, and self-consistent."""

import unittest

from port_doctor import services


class PortTableTests(unittest.TestCase):
    def test_ports_are_valid_tcp(self):
        for port in services.PORTS:
            self.assertIsInstance(port, int)
            self.assertGreaterEqual(port, 1)
            self.assertLessEqual(port, 65535)

    def test_every_entry_has_a_known_class(self):
        known = {"remote", "web", "file", "print", "media",
                 "iot", "db", "mail", "infra"}
        for port, (name, klass) in services.PORTS.items():
            self.assertIn(klass, known, (port, name, klass))
            self.assertTrue(name)
            self.assertTrue(name.isprintable())

    def test_discovery_ports_are_a_subset(self):
        for port in services.DISCOVERY_PORTS:
            self.assertIn(port, services.PORTS)

    def test_all_ports_sorted(self):
        self.assertEqual(services.ALL_PORTS, sorted(services.PORTS))

    def test_describe_known_and_unknown(self):
        self.assertEqual(services.describe(22), ("ssh", "remote"))
        self.assertEqual(services.describe(443), ("https", "web"))
        self.assertEqual(services.describe(1), ("tcp", "unknown"))
        self.assertEqual(services.describe(65000), ("tcp", "unknown"))


if __name__ == "__main__":
    unittest.main()
