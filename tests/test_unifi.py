"""UniFi controller census: config parsing, key guards, normalization.

Every network touch is an injected opener; nothing here leaves the host.
"""

import builtins
import errno
import json
import os
import stat
import tempfile
import unittest
from unittest.mock import patch

from port_doctor import unifi


def write_env(root, text, name="port-doctor/unifi.env", mode=0o600):
    path = os.path.join(root, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)
    os.chmod(path, mode)
    return path


def valid_env(key="k"):
    return f"UNIFI_HOST=10.70.120.1\nUNIFI_API_KEY={key}\n"


def fd_count():
    return len(os.listdir("/proc/self/fd"))


def stat_with_uid(st, uid):
    values = list(st)
    values[4] = uid
    return os.stat_result(values)


def stat_with_mode(st, mode):
    values = list(st)
    values[0] = mode
    return os.stat_result(values)


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


class PrivateConfigTests(unittest.TestCase):
    """The API key file must be a private regular file, opened then fstat'd."""

    def assert_rejected(self, config, error, path, *needles):
        self.assertIsNone(config)
        self.assertIsNotNone(error)
        self.assertIsInstance(error, str)
        self.assertIn(os.path.basename(path), error)
        lower = error.lower()
        self.assertTrue(any(needle.lower() in lower for needle in needles),
                        error)

    def assert_no_secret(self, error, secret):
        self.assertNotIn(secret, error or "")

    def test_private_0600_regular_file_is_accepted(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env("private-0600"), mode=0o600)
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "private-0600")
        self.assertEqual(config["host"], "10.70.120.1")

    def test_owner_read_only_0400_regular_file_is_accepted(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env("private-0400"), mode=0o400)
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "private-0400")

    def test_world_readable_0644_is_rejected(self):
        secret = "leak-me-credential-0644"
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env(secret), mode=0o644)
            config, error = unifi.load_config(paths=[path])
        self.assert_rejected(config, error, path,
                             "permission", "mode", "0600", "group", "other")
        self.assert_no_secret(error, secret)

    def test_each_group_or_other_bit_is_rejected(self):
        bits = {
            "g+r": 0o640,
            "g+w": 0o620,
            "g+x": 0o610,
            "o+r": 0o604,
            "o+w": 0o602,
            "o+x": 0o601,
        }
        for label, mode in bits.items():
            with self.subTest(label=label, mode=oct(mode)):
                secret = f"leak-{label}"
                with tempfile.TemporaryDirectory() as root:
                    path = write_env(root, valid_env(secret), mode=mode)
                    config, error = unifi.load_config(paths=[path])
                self.assert_rejected(config, error, path,
                                     "permission", "mode", "0600",
                                     "group", "other")
                self.assert_no_secret(error, secret)

    def test_symlink_to_a_private_file_is_rejected(self):
        secret = "symlink-target-key"
        with tempfile.TemporaryDirectory() as root:
            target = write_env(root, valid_env(secret),
                               name="target.env", mode=0o600)
            path = os.path.join(root, "unifi.env")
            os.symlink(target, path)
            config, error = unifi.load_config(paths=[path])
        self.assert_rejected(config, error, path, "symlink")
        self.assert_no_secret(error, secret)

    def test_dangling_symlink_is_rejected_not_treated_as_absent(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "unifi.env")
            os.symlink(os.path.join(root, "missing.env"), path)
            config, error = unifi.load_config(paths=[path])
        self.assert_rejected(config, error, path, "symlink")

    def test_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "unifi.env")
            os.mkdir(path)
            os.chmod(path, 0o700)
            config, error = unifi.load_config(paths=[path])
        self.assert_rejected(config, error, path, "regular", "directory",
                             "file")

    def test_fifo_is_rejected_without_blocking(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "unifi.env")
            os.mkfifo(path)
            os.chmod(path, 0o600)
            real_os_open = os.open
            real_builtin_open = builtins.open

            def guarded_os_open(name, flags, *args, **kwargs):
                if os.path.abspath(str(name)) == os.path.abspath(path):
                    nonblock = bool(flags & os.O_NONBLOCK)
                    opath = bool(flags & getattr(os, "O_PATH", 0))
                    if not (nonblock or opath):
                        raise AssertionError(
                            "FIFO opened without O_NONBLOCK or O_PATH")
                return real_os_open(name, flags, *args, **kwargs)

            def guarded_builtin_open(name, *args, **kwargs):
                if os.path.abspath(str(name)) == os.path.abspath(path):
                    raise OSError(errno.ENXIO, "No such device or address")
                return real_builtin_open(name, *args, **kwargs)

            with patch("os.open", guarded_os_open), \
                 patch("builtins.open", guarded_builtin_open):
                config, error = unifi.load_config(paths=[path])
        self.assert_rejected(config, error, path, "regular", "fifo", "pipe",
                             "file")

    def test_fifo_type_from_fstat_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env("fifo-key"), mode=0o600)
            real_fstat = os.fstat

            def fifo_fstat(fd):
                st = real_fstat(fd)
                try:
                    same = os.path.samefile(f"/proc/self/fd/{fd}", path)
                except OSError:
                    same = False
                if not same:
                    return st
                mode = stat.S_IFIFO | (st.st_mode & 0o777)
                return stat_with_mode(st, mode)

            with patch("os.fstat", fifo_fstat):
                config, error = unifi.load_config(paths=[path])
        self.assert_rejected(config, error, path, "regular", "fifo", "pipe",
                             "file")
        self.assert_no_secret(error, "fifo-key")

    def test_foreign_uid_from_patched_fstat_is_rejected(self):
        secret = "foreign-uid-key"
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env(secret), mode=0o600)
            real_fstat = os.fstat
            foreign = os.geteuid() + 1

            def patched_fstat(fd):
                st = real_fstat(fd)
                try:
                    same = os.path.samefile(f"/proc/self/fd/{fd}", path)
                except OSError:
                    same = False
                if not same:
                    return st
                return stat_with_uid(st, foreign)

            with patch("os.fstat", patched_fstat):
                config, error = unifi.load_config(paths=[path])
        self.assert_rejected(config, error, path, "owner", "owned", "uid")
        self.assert_no_secret(error, secret)

    def test_invalid_metadata_is_not_read_or_parsed(self):
        parsed = []
        reads = []
        fdopens = []
        real_parse = unifi._parse_env
        real_read = os.read
        real_fdopen = os.fdopen
        real_fstat = os.fstat

        def tracking_parse(text):
            parsed.append(True)
            return real_parse(text)

        def tracking_read(fd, n):
            reads.append(fd)
            return real_read(fd, n)

        def tracking_fdopen(fd, *args, **kwargs):
            fdopens.append(fd)
            return real_fdopen(fd, *args, **kwargs)

        def check(config, error, path, secret, *needles):
            self.assert_rejected(config, error, path, *needles)
            self.assertEqual(parsed, [])
            self.assertEqual(reads, [])
            self.assertEqual(fdopens, [])
            if secret:
                self.assert_no_secret(error, secret)

        with patch.object(unifi, "_parse_env", tracking_parse), \
             patch("os.read", tracking_read), \
             patch("os.fdopen", tracking_fdopen):
            with tempfile.TemporaryDirectory() as root:
                path = write_env(root, valid_env("no-read-0644"), mode=0o644)
                check(*unifi.load_config(paths=[path]), path, "no-read-0644",
                      "permission", "mode", "0600", "group", "other")

                path = os.path.join(root, "as-dir.env")
                os.mkdir(path)
                os.chmod(path, 0o700)
                check(*unifi.load_config(paths=[path]), path, None,
                      "regular", "directory", "file")

                target = write_env(root, valid_env("no-read-symlink"),
                                   name="target.env", mode=0o600)
                path = os.path.join(root, "link.env")
                os.symlink(target, path)
                check(*unifi.load_config(paths=[path]), path,
                      "no-read-symlink", "symlink")

                path = write_env(root, valid_env("no-read-uid"),
                                 name="owned.env", mode=0o600)

                def foreign_fstat(fd):
                    st = real_fstat(fd)
                    try:
                        same = os.path.samefile(f"/proc/self/fd/{fd}", path)
                    except OSError:
                        same = False
                    if not same:
                        return st
                    return stat_with_uid(st, os.geteuid() + 1)

                with patch("os.fstat", foreign_fstat):
                    check(*unifi.load_config(paths=[path]), path,
                          "no-read-uid", "owner", "owned", "uid")

                path = write_env(root, valid_env("no-read-fifo"),
                                 name="fifo-lookalike.env", mode=0o600)

                def fifo_fstat(fd):
                    st = real_fstat(fd)
                    try:
                        same = os.path.samefile(f"/proc/self/fd/{fd}", path)
                    except OSError:
                        same = False
                    if not same:
                        return st
                    return stat_with_mode(
                        st, stat.S_IFIFO | (st.st_mode & 0o777))

                with patch("os.fstat", fifo_fstat):
                    check(*unifi.load_config(paths=[path]), path,
                          "no-read-fifo", "regular", "fifo", "pipe", "file")

    def test_config_read_is_bounded(self):
        header = valid_env("bounded-key")
        text = header + ("# " + "x" * unifi._MAX_CONFIG + "\n")
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, text, mode=0o600)
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "bounded-key")

    def test_keys_past_the_byte_bound_are_ignored(self):
        text = ("# " + "x" * unifi._MAX_CONFIG + "\n" + valid_env("late-key"))
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, text, mode=0o600)
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(config)
        self.assert_no_secret(error, "late-key")

    def test_fstat_before_read_uses_the_same_descriptor_under_replacement(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env("original-key"), mode=0o600)
            real_open = os.open
            real_fstat = os.fstat
            real_read = os.read
            real_fdopen = os.fdopen
            opened = []
            events = []

            def tracking_open(name, flags, *args, **kwargs):
                fd = real_open(name, flags, *args, **kwargs)
                if os.path.abspath(str(name)) == os.path.abspath(path):
                    opened.append(fd)
                    events.append(("open", fd, flags))
                    os.unlink(path)
                    with open(path, "w") as handle:
                        handle.write(valid_env("replaced-key"))
                    os.chmod(path, 0o644)
                return fd

            def tracking_fstat(fd):
                events.append(("fstat", fd, None))
                return real_fstat(fd)

            def tracking_read(fd, n):
                events.append(("read", fd, n))
                return real_read(fd, n)

            def tracking_fdopen(fd, *args, **kwargs):
                events.append(("fdopen", fd, None))
                return real_fdopen(fd, *args, **kwargs)

            with patch("os.open", tracking_open), \
                 patch("os.fstat", tracking_fstat), \
                 patch("os.read", tracking_read), \
                 patch("os.fdopen", tracking_fdopen):
                config, error = unifi.load_config(paths=[path])

        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "original-key")
        self.assertTrue(opened, "config must os.open the credential path")
        fd = opened[0]
        self.assertTrue(any(kind == "fstat" and item == fd
                            for kind, item, _ in events))
        self.assertTrue(any(kind in ("read", "fdopen") and item == fd
                            for kind, item, _ in events))
        fstat_at = next(i for i, event in enumerate(events)
                        if event[0] == "fstat" and event[1] == fd)
        consume_at = next(i for i, event in enumerate(events)
                          if event[0] in ("read", "fdopen") and event[1] == fd)
        self.assertLess(fstat_at, consume_at)
        self.assertTrue(any(event[0] == "open" and event[2] & os.O_NOFOLLOW
                            for event in events))

    def test_fd_is_closed_when_permission_validation_fails(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env("close-on-mode"), mode=0o644)
            real_open = os.open
            real_close = os.close
            opened = []

            def tracking_open(name, flags, *args, **kwargs):
                fd = real_open(name, flags, *args, **kwargs)
                if os.path.abspath(str(name)) == os.path.abspath(path):
                    opened.append(fd)
                return fd

            def tracking_close(fd):
                return real_close(fd)

            before = fd_count()
            still_open = []
            with patch("os.open", tracking_open), \
                 patch("os.close", tracking_close):
                for _ in range(8):
                    config, error = unifi.load_config(paths=[path])
                for fd in set(opened):
                    try:
                        os.fstat(fd)
                    except OSError:
                        continue
                    still_open.append(fd)
            after = fd_count()

        self.assertIsNone(config)
        self.assertIsNotNone(error)
        self.assertTrue(opened, "config must os.open before rejecting mode")
        self.assertEqual(still_open, [])
        self.assertLessEqual(after, before + 2)

    def test_fd_is_closed_when_read_fails(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env("close-on-read"), mode=0o600)
            real_open = os.open
            real_fdopen = os.fdopen
            opened = []

            def tracking_open(name, flags, *args, **kwargs):
                fd = real_open(name, flags, *args, **kwargs)
                if os.path.abspath(str(name)) == os.path.abspath(path):
                    opened.append(fd)
                return fd

            def boom_read(fd, n):
                raise OSError("read failed")

            def boom_fdopen(fd, *args, **kwargs):
                handle = real_fdopen(fd, *args, **kwargs)

                def boom(*args, **kwargs):
                    raise OSError("read failed")

                handle.read = boom
                return handle

            before = fd_count()
            still_open = []
            with patch("os.open", tracking_open), \
                 patch("os.read", boom_read), \
                 patch("os.fdopen", boom_fdopen):
                for _ in range(8):
                    config, error = unifi.load_config(paths=[path])
                for fd in set(opened):
                    try:
                        os.fstat(fd)
                    except OSError:
                        continue
                    still_open.append(fd)
            after = fd_count()

        self.assertIsNone(config)
        self.assertTrue(opened, "config must os.open the credential path")
        self.assertEqual(still_open, [])
        self.assertLessEqual(after, before + 2)

    def test_insecure_file_is_not_treated_as_absent(self):
        with tempfile.TemporaryDirectory() as root:
            path = write_env(root, valid_env("visible-key"), mode=0o644)
            config, error = unifi.load_config(
                paths=[path, "/nonexistent/port-doctor.env"])
        self.assertIsNone(config)
        self.assertIsNotNone(error)
        self.assert_no_secret(error, "visible-key")

    def test_later_private_file_is_used_when_earlier_file_is_insecure(self):
        with tempfile.TemporaryDirectory() as root:
            bad = write_env(root, valid_env("insecure-key"),
                            name="a.env", mode=0o644)
            good = write_env(root, valid_env("private-key"),
                             name="b.env", mode=0o600)
            config, error = unifi.load_config(paths=[bad, good])
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "private-key")

    def test_override_path_is_used_when_private(self):
        with tempfile.TemporaryDirectory() as home:
            override = write_env(home, valid_env("override-key"),
                                 name="custom.env", mode=0o600)
            write_env(home, valid_env("default-key"),
                      name=".config/port-doctor/unifi.env", mode=0o600)
            config, error = unifi.load_config(environ={
                "HOME": home,
                "PORT_DOCTOR_UNIFI_CONFIG": override,
            })
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "override-key")

    def test_insecure_override_is_not_loaded(self):
        secret = "override-insecure"
        with tempfile.TemporaryDirectory() as home:
            override = write_env(home, valid_env(secret),
                                 name="custom.env", mode=0o644)
            config, error = unifi.load_config(environ={
                "HOME": home,
                "PORT_DOCTOR_UNIFI_CONFIG": override,
            })
        self.assert_rejected(config, error, override,
                             "permission", "mode", "0600", "group", "other")
        self.assert_no_secret(error, secret)

    def test_default_fallback_to_unifi_env_when_port_doctor_file_is_absent(self):
        with tempfile.TemporaryDirectory() as home:
            write_env(home, valid_env("shared-key"),
                      name=".config/unifi/env", mode=0o600)
            config, error = unifi.load_config(environ={"HOME": home})
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "shared-key")

    def test_insecure_default_port_doctor_file_falls_back_to_private_unifi_env(
            self):
        with tempfile.TemporaryDirectory() as home:
            write_env(home, valid_env("insecure-default"),
                      name=".config/port-doctor/unifi.env", mode=0o644)
            write_env(home, valid_env("shared-private"),
                      name=".config/unifi/env", mode=0o600)
            config, error = unifi.load_config(environ={"HOME": home})
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "shared-private")

    def test_empty_override_falls_through_to_home_paths(self):
        with tempfile.TemporaryDirectory() as home:
            write_env(home, valid_env("home-key"),
                      name=".config/port-doctor/unifi.env", mode=0o600)
            config, error = unifi.load_config(environ={
                "HOME": home,
                "PORT_DOCTOR_UNIFI_CONFIG": "",
            })
        self.assertIsNone(error)
        self.assertEqual(config["apiKey"], "home-key")

    def test_absent_paths_are_still_not_configured(self):
        with tempfile.TemporaryDirectory() as home:
            config, error = unifi.load_config(environ={"HOME": home})
        self.assertIsNone(config)
        self.assertIsNone(error)


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
        self.assertIn("connection failed", census["error"])
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
        self.assertIn("invalid controller configuration or response", census["error"])
        self.assertEqual(census["clients"], [])

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
