"""UniFi controller census: config parsing, key guards, normalization.

Every network touch is an injected opener; nothing here leaves the host.
"""

import json
import os
import tempfile
import unittest

from port_doctor import unifi


def write_env(root, text, name="port-doctor/unifi.env"):
    path = os.path.join(root, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)
    return path


class FakeResponse:
    def __init__(self, payload):
        self.blob = json.dumps(payload).encode()

    def read(self, limit=-1):
        return self.blob[:limit if limit >= 0 else None]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


STA = {"data": [
    {"ip": "10.70.0.42", "mac": "A4:B1:97:11:22:33", "name": "studio",
     "hostname": "studio-lan", "network": "Default", "vlan": 0},
    {"ip": "10.70.90.20", "mac": "40:b4:cd:44:55:66", "hostname": "echo-k",
     "network": "IoT", "vlan": 3},
    {"ip": "8.8.8.8", "mac": "00:11:22:33:44:55", "name": "impossible"},
    {"ip": "not-an-ip", "name": "garbage"},
    {"ip": "10.70.0.42", "mac": "a4:b1:97:11:22:33", "name": "dupe"},
    "not-a-dict",
]}

NETWORKCONF = {"data": [
    {"name": "Default", "vlan": 0, "ip_subnet": "10.70.0.0/24"},
    {"name": "IoT", "vlan": 3, "ip_subnet": "10.70.90.0/24"},
    {"name": "SHACK NETWORK", "vlan": 4, "ip_subnet": "10.70.120.50/24"},
    {"name": "broken"},
    "not-a-dict",
]}


def fake_opener(request, timeout=0):
    if request.full_url.endswith("/stat/sta"):
        return FakeResponse(STA)
    if request.full_url.endswith("/rest/networkconf"):
        return FakeResponse(NETWORKCONF)
    raise AssertionError("unexpected URL " + request.full_url)


class ConfigTests(unittest.TestCase):
    def test_absent_files_mean_not_configured(self):
        config, error = unifi.load_config(paths=["/nonexistent/x.env"])
        self.assertIsNone(config)
        self.assertIsNone(error)

    def test_parses_env_file(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, "# comment\n"
                                   "export UNIFI_HOST=10.70.120.1\n"
                                   "UNIFI_API_KEY=\"abc123\"\n"
                                   "UNIFI_SITE='default'\n"
                                   "UNIFI_VERIFY_TLS=true\n")
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(error)
        self.assertEqual(config["host"], "10.70.120.1")
        self.assertEqual(config["apiKey"], "abc123")
        self.assertEqual(config["site"], "default")
        self.assertTrue(config["verifyTls"])

    def test_public_host_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, "UNIFI_HOST=8.8.8.8\nUNIFI_API_KEY=k\n")
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(config)
        self.assertIn("private", error)

    def test_hostname_is_rejected(self):
        # A name can be rebound to a public address; the key may only ride
        # to a private literal.
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, "UNIFI_HOST=udm.local\nUNIFI_API_KEY=k\n")
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(config)
        self.assertIn("literal", error)

    def test_link_local_and_loopback_are_rejected(self):
        for host in ("169.254.1.1", "127.0.0.1"):
            with tempfile.TemporaryDirectory() as root:
                path = write_env(root,
                                 f"UNIFI_HOST={host}\nUNIFI_API_KEY=k\n")
                config, _ = unifi.load_config(paths=[path])
            self.assertIsNone(config, host)

    def test_missing_key_is_reported(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, "UNIFI_HOST=10.70.120.1\n")
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(config)
        self.assertIn("UNIFI_API_KEY", error)

    def test_shared_unifi_env_convention_is_read(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, "UNIFI_HOST=10.70.120.1\nUNIFI_API_KEY=k\n",
                             name="unifi/env")
            config, _ = unifi.load_config(paths=["/nonexistent", path])
        self.assertIsNotNone(config)
        self.assertEqual(config["host"], "10.70.120.1")


class CensusTests(unittest.TestCase):
    def config(self):
        return {"host": "10.70.120.1", "site": "default", "apiKey": "k",
                "verifyTls": False}

    def test_clients_and_networks_normalize(self):
        census = unifi.controller_census(config=self.config(),
                                         opener=fake_opener)
        self.assertTrue(census["configured"])
        self.assertIsNone(census["error"])
        self.assertEqual(census["host"], "10.70.120.1")

        clients = {c["ip"]: c for c in census["clients"]}
        # Public and malformed records never reach the scanner.
        self.assertNotIn("8.8.8.8", clients)
        self.assertNotIn("not-an-ip", clients)
        # First record wins on a duplicate IP.
        self.assertEqual(len(clients), 2)
        studio = clients["10.70.0.42"]
        self.assertEqual(studio["name"], "studio")  # name beats hostname
        self.assertEqual(studio["mac"], "a4:b1:97:11:22:33")  # lowercased
        self.assertEqual(studio["network"], "Default")
        self.assertEqual(studio["vlan"], 0)
        echo = clients["10.70.90.20"]
        self.assertEqual(echo["name"], "echo-k")  # hostname as fallback
        self.assertEqual(echo["vlan"], 3)

        networks = census["networks"]
        self.assertEqual(len(networks), 3)  # the subnet-less one dropped
        shack = [n for n in networks if n["name"] == "SHACK NETWORK"][0]
        self.assertEqual(shack["subnet"], "10.70.120.0/24")  # masked
        self.assertEqual(shack["vlan"], 4)

    def test_api_key_rides_the_header(self):
        seen = []

        def opener(request, timeout=0):
            seen.append(dict(request.header_items()))
            return fake_opener(request, timeout)

        unifi.controller_census(config=self.config(), opener=opener)
        self.assertTrue(any(headers.get("X-api-key") == "k"
                            for headers in seen))

    def test_failure_is_an_error_string_not_an_exception(self):
        def dead_opener(request, timeout=0):
            raise OSError("connection refused")

        census = unifi.controller_census(config=self.config(),
                                         opener=dead_opener)
        self.assertTrue(census["configured"])
        self.assertIn("refused", census["error"])
        self.assertEqual(census["clients"], [])

    def test_client_cap_is_enforced(self):
        many = {"data": [{"ip": f"10.99.{i // 256}.{i % 256}", "name": f"h{i}"}
                         for i in range(unifi.MAX_CLIENTS + 50)]}

        def opener(request, timeout=0):
            if request.full_url.endswith("/stat/sta"):
                return FakeResponse(many)
            raise OSError("no networks")

        census = unifi.controller_census(config=self.config(), opener=opener)
        self.assertEqual(len(census["clients"]), unifi.MAX_CLIENTS)
        self.assertEqual(census["networks"], [])  # label fetch may fail free

    def test_oversized_response_is_rejected(self):
        class Huge:
            def read(self, limit=-1):
                return b"x" * (unifi._MAX_RESPONSE + 1)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        census = unifi.controller_census(
            config=self.config(), opener=lambda request, timeout=0: Huge())
        self.assertIn("2 MiB", census["error"])

    def test_network_for_ip(self):
        networks = [{"name": "IoT", "vlan": 3, "subnet": "10.70.90.0/24"}]
        self.assertEqual(unifi.network_for_ip("10.70.90.7", networks),
                         ("IoT", 3))
        self.assertEqual(unifi.network_for_ip("10.70.0.7", networks),
                         ("", None))
        self.assertEqual(unifi.network_for_ip("junk", networks), ("", None))

    def test_malformed_mac_is_discarded(self):
        bad = {"data": [{"ip": "10.70.0.55", "mac": "zz:zz:zz:zz:zz:zz",
                         "name": "broken"}]}

        def opener(request, timeout=0):
            if request.full_url.endswith("/stat/sta"):
                return FakeResponse(bad)
            raise OSError("no networks")

        census = unifi.controller_census(config=self.config(), opener=opener)
        self.assertEqual(census["clients"][0]["mac"], "")

    def test_non_list_data_never_raises(self):
        weird = {"data": {"not": "a list"}}

        def opener(request, timeout=0):
            return FakeResponse(weird)

        census = unifi.controller_census(config=self.config(), opener=opener)
        self.assertIsNone(census["error"])
        self.assertEqual(census["clients"], [])
        self.assertEqual(census["networks"], [])

    def test_config_host_is_revalidated_before_the_key_rides(self):
        calls = []

        def opener(request, timeout=0):
            calls.append(request.full_url)
            return FakeResponse(STA)

        config = {"host": "8.8.8.8", "site": "default", "apiKey": "k",
                  "verifyTls": False}
        census = unifi.controller_census(config=config, opener=opener)
        self.assertEqual(calls, [])
        self.assertIn("private", census["error"])


if __name__ == "__main__":
    unittest.main()
