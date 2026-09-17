"""Payload composition: the identity block and self-hostname backfill."""

import unittest
from unittest import mock

from port_doctor import scanner


def fake_lan():
    return {
        "network": {"cidr": "10.70.120.0/24", "ifname": "wlan0",
                    "selfIp": "10.70.120.50", "gateway": "10.70.120.1",
                    "truncated": False, "passiveOnly": False, "note": ""},
        "controller": {"configured": False, "host": "", "site": "",
                       "clients": 0, "error": None},
        "hosts": [
            {"ip": "10.70.120.50", "hostname": "", "isSelf": True},
            {"ip": "10.70.120.99", "hostname": "pi-hole",
             "isSelf": False},
        ],
        "stats": {"targets": 254, "hostsUp": 2, "openPorts": 0,
                  "scanMs": 10, "discoveryMs": 5, "controllerMs": 0,
                  "deadlineHit": False},
    }


IDENTITY = {"hostname": "xps16", "model": "XPS 16 DA16260",
            "manufacturer": "Dell Inc.", "label": "xps16"}


class LanPayloadTests(unittest.TestCase):
    def test_identity_present_and_self_hostname_backfilled(self):
        with mock.patch.object(scanner.scan, "scan_lan",
                               side_effect=lambda port_list=None: fake_lan()), \
             mock.patch.object(scanner.identity, "computer_identity",
                               return_value=dict(IDENTITY)):
            payload = scanner.lan_payload()
        self.assertIsNone(payload["error"])
        self.assertEqual(payload["identity"]["label"], "xps16")
        self.assertEqual(payload["identity"]["model"], "XPS 16 DA16260")
        hosts = {h["ip"]: h for h in payload["hosts"]}
        # The resolver left the self host nameless; identity names it.
        self.assertEqual(hosts["10.70.120.50"]["hostname"], "xps16")
        # Real names from the network are never overwritten.
        self.assertEqual(hosts["10.70.120.99"]["hostname"], "pi-hole")
        self.assertEqual(payload["controller"]["configured"], False)

    def test_scan_failure_still_carries_identity_shape(self):
        with mock.patch.object(scanner.scan, "scan_lan",
                               side_effect=RuntimeError("boom")), \
             mock.patch.object(scanner.identity, "computer_identity",
                               return_value=dict(IDENTITY)):
            payload = scanner.lan_payload()
        self.assertEqual(payload["error"], "boom")
        self.assertEqual(payload["identity"]["label"], "xps16")
        self.assertEqual(payload["hosts"], [])
        self.assertIn("controller", payload)


class MachinePayloadTests(unittest.TestCase):
    def test_identity_present(self):
        snapshot = {"hostname": "xps16", "listeners": [], "connections": [],
                    "stats": {"listeners": 0, "connections": 0,
                              "truncatedListeners": 0,
                              "truncatedConnections": 0}}
        with mock.patch.object(scanner.net, "interfaces", return_value=[]), \
             mock.patch.object(scanner.machine, "machine_snapshot",
                               return_value=snapshot), \
             mock.patch.object(scanner.identity, "computer_identity",
                               return_value=dict(IDENTITY)):
            payload = scanner.machine_payload()
        self.assertIsNone(payload["error"])
        self.assertEqual(payload["identity"]["hostname"], "xps16")
        self.assertEqual(payload["hostname"], "xps16")


if __name__ == "__main__":
    unittest.main()
