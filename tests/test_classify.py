"""Device typing: every label comes from evidence, or it's "unknown"."""

import unittest

from port_doctor import classify


def host(isGateway=False, isSelf=False, vendor="", hostname="", ports=()):
    return {"isGateway": isGateway, "isSelf": isSelf, "vendor": vendor,
            "hostname": hostname,
            "ports": [{"port": p, "proto": "tcp", "service": "x",
                       "class": "web"} for p in ports]}


class ClassifyTests(unittest.TestCase):
    def test_gateway_and_self(self):
        self.assertEqual(classify.classify(host(isGateway=True)), "router")
        self.assertEqual(classify.classify(host(isSelf=True), chassis="laptop"),
                         "laptop")
        self.assertEqual(classify.classify(host(isSelf=True), chassis="desktop"),
                         "desktop")

    def test_vendor_driven(self):
        self.assertEqual(classify.classify(host(vendor="Raspberry Pi")),
                         "raspberry-pi")
        self.assertEqual(classify.classify(host(vendor="Synology")), "nas")
        self.assertEqual(classify.classify(host(vendor="QNAP")), "nas")
        self.assertEqual(classify.classify(host(vendor="Roku")), "tv")
        self.assertEqual(classify.classify(host(vendor="Espressif")), "iot")
        self.assertEqual(classify.classify(host(vendor="Apple", ports=(22,))),
                         "computer")

    def test_name_driven(self):
        self.assertEqual(classify.classify(host(hostname="Jillians-iPhone")),
                         "phone")
        self.assertEqual(classify.classify(host(hostname="Carter-iPad.local")),
                         "tablet")
        self.assertEqual(classify.classify(host(hostname="living-room-cam")),
                         "camera")
        self.assertEqual(classify.classify(host(hostname="xbox-one")), "console")
        self.assertEqual(classify.classify(host(hostname="truenas")), "nas")
        self.assertEqual(classify.classify(host(hostname="home-assistant")),
                         "iot")
        self.assertEqual(classify.classify(host(hostname="bravia-tv")), "tv")
        self.assertEqual(classify.classify(host(hostname="eero-yfzq.local")),
                         "router")
        self.assertEqual(classify.classify(host(hostname="Cliffords-Mac-mini.local")),
                         "desktop")
        self.assertEqual(classify.classify(host(hostname="Amandas-MacBook-Pro")),
                         "laptop")

    def test_port_driven(self):
        self.assertEqual(classify.classify(host(ports=(9100,))), "printer")
        self.assertEqual(classify.classify(host(ports=(554,))), "camera")
        self.assertEqual(classify.classify(host(ports=(1883,))), "iot")
        self.assertEqual(classify.classify(host(ports=(445, 548, 5000))), "nas")
        self.assertEqual(classify.classify(host(vendor="Samsung",
                                                ports=(8009,))), "tv")
        self.assertEqual(classify.classify(host(vendor="Microsoft")), "console")
        self.assertEqual(classify.classify(host(vendor="Microsoft",
                                                ports=(445,))), "computer")

    def test_rtsp_with_computer_services_is_not_a_camera(self):
        self.assertNotEqual(classify.classify(host(ports=(554, 22, 445))),
                            "camera")

    def test_unknown_stays_unknown(self):
        self.assertEqual(classify.classify(host()), "unknown")
        self.assertEqual(classify.classify(host(vendor="Aastra", ports=(5060,))
                                           ), "unknown")


if __name__ == "__main__":
    unittest.main()
