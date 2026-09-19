"""Exercise the real HTTP handler chain with an in-memory transport only."""

import io
import json
import os
import ssl
import tempfile
import unittest
import urllib.error
import urllib.request
import urllib.response
from email.message import Message
from unittest.mock import patch

from port_doctor import unifi


class TransportTests(unittest.TestCase):
    def config(self):
        return {"host": "192.168.4.1", "site": "default",
                "apiKey": "test-credential", "verifyTls": True}

    def response(self, request, code=200, location=None):
        headers = Message()
        if location:
            headers["Location"] = location
        response = urllib.response.addinfourl(
            io.BytesIO(b'{"data":[]}'), headers, request.full_url, code)
        response.msg = "fixture response"
        return response

    def test_redirects_never_forward_credentials(self):
        for code in (301, 302, 303, 307, 308):
            for target in ("https://example.com/collect",
                           "http://example.com/collect",
                           "https://192.168.4.2/collect", "/other"):
                with self.subTest(code=code, target=target):
                    seen = []

                    def transport(handler, request):
                        seen.append((request.full_url,
                                     request.get_header("X-api-key")))
                        return self.response(request, code, target) if len(seen) == 1 \
                            else self.response(request)

                    with patch.dict(os.environ, {}, clear=True), \
                         patch.object(urllib.request.HTTPSHandler, "https_open", transport), \
                         patch.object(urllib.request.HTTPHandler, "http_open", transport):
                        census = unifi.controller_census(config=self.config())
                    self.assertEqual(len(seen), 1, seen)
                    self.assertEqual(seen[0][1], "test-credential")
                    self.assertIsNotNone(census["error"])

    def test_environment_proxy_cannot_receive_controller_connection(self):
        seen = []

        def transport(handler, request):
            seen.append(request.host)
            return self.response(request)

        with patch.dict(os.environ, {"https_proxy": "http://example.com:8080"},
                        clear=True), \
             patch.object(urllib.request.HTTPSHandler, "https_open", transport), \
             patch.object(urllib.request.HTTPHandler, "http_open", transport):
            census = unifi.controller_census(config=self.config())
        self.assertIsNone(census["error"])
        self.assertEqual(seen, ["192.168.4.1", "192.168.4.1"])

    def test_certificate_verification_defaults_on(self):
        for setting in ("", "UNIFI_VERIFY_TLS=garbage\n", "UNIFI_VERIFY_TLS=true\n"):
            with self.subTest(setting=setting), tempfile.TemporaryDirectory() as root:
                path = os.path.join(root, "fixture.env")
                with open(path, "w") as handle:
                    handle.write("UNIFI_HOST=192.168.4.1\nUNIFI_API_KEY=k\n" + setting)
                os.chmod(path, 0o600)
                config, error = unifi.load_config(paths=[path])
            self.assertIsNone(error)
            self.assertTrue(config["verifyTls"])

    def test_explicit_certificate_opt_out_still_works(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "fixture.env")
            with open(path, "w") as handle:
                handle.write("UNIFI_HOST=192.168.4.1\nUNIFI_API_KEY=k\n"
                             "UNIFI_VERIFY_TLS=false\n")
            os.chmod(path, 0o600)
            config, error = unifi.load_config(paths=[path])
        self.assertIsNone(error)
        self.assertFalse(config["verifyTls"])

    def test_tls_context_applies_verification_choice(self):
        for verify in (True, False):
            seen = []

            def transport(handler, request):
                seen.append((handler._context.verify_mode,
                             handler._context.check_hostname))
                return self.response(request)

            config = self.config()
            config["verifyTls"] = verify
            with patch.dict(os.environ, {}, clear=True), \
                 patch.object(urllib.request.HTTPSHandler, "https_open", transport):
                census = unifi.controller_census(config=config)
            self.assertIsNone(census["error"])
            self.assertEqual(seen, [(ssl.CERT_REQUIRED if verify else ssl.CERT_NONE,
                                     verify)] * 2)

    def test_error_text_does_not_expose_api_key(self):
        def transport(request, timeout=0):
            raise ValueError("invalid header " + request.get_header("X-api-key"))

        census = unifi.controller_census(config=self.config(), opener=transport)
        self.assertNotIn("test-credential", json.dumps(census))
        self.assertIsNotNone(census["error"])

    def test_http_error_reports_only_status_and_closes_response(self):
        body = io.BytesIO(b"private response body")
        raised = []  # Keep the exception alive so finalization cannot close it.

        def transport(request, timeout=0):
            error = urllib.error.HTTPError(
                request.full_url, 401, "test-credential echoed by peer",
                Message(), body)
            raised.append(error)
            raise error

        census = unifi.controller_census(config=self.config(), opener=transport)
        self.assertEqual(census["error"], "controller HTTP request failed (401)")
        self.assertNotIn("test-credential", json.dumps(census))
        self.assertTrue(body.closed)
