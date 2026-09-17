"""Machine identity: kernel hostname, DMI model, honest fallbacks."""

import os
import tempfile
import unittest

from port_doctor import identity


def make_sysroot(root, product=None, vendor=None, dt_model=None):
    if product is not None or vendor is not None:
        dmi = os.path.join(root, "class", "dmi", "id")
        os.makedirs(dmi)
        if product is not None:
            with open(os.path.join(dmi, "product_name"), "w") as handle:
                handle.write(product)
        if vendor is not None:
            with open(os.path.join(dmi, "sys_vendor"), "w") as handle:
                handle.write(vendor)
    if dt_model is not None:
        dt = os.path.join(root, "firmware", "devicetree", "base")
        os.makedirs(dt)
        with open(os.path.join(dt, "model"), "w") as handle:
            handle.write(dt_model)


class IdentityTests(unittest.TestCase):
    def test_dmi_product_and_vendor(self):
        with tempfile.TemporaryDirectory() as root:
            make_sysroot(root, product="XPS 16 DA16260\n",
                         vendor="Dell Inc.\n")
            info = identity.computer_identity(sys_root=root,
                                              hostname="xps16")
        self.assertEqual(info["hostname"], "xps16")
        self.assertEqual(info["model"], "XPS 16 DA16260")
        self.assertEqual(info["manufacturer"], "Dell Inc.")
        self.assertEqual(info["label"], "xps16")

    def test_devicetree_fallback_for_arm_boards(self):
        with tempfile.TemporaryDirectory() as root:
            make_sysroot(root,
                         dt_model="Raspberry Pi 5 Model B Rev 1.0\x00")
            info = identity.computer_identity(sys_root=root,
                                              hostname="g2-pi")
        self.assertEqual(info["model"], "Raspberry Pi 5 Model B Rev 1.0")
        self.assertEqual(info["manufacturer"], "")
        self.assertEqual(info["label"], "g2-pi")

    def test_junk_firmware_strings_become_empty(self):
        with tempfile.TemporaryDirectory() as root:
            make_sysroot(root, product="To Be Filled By O.E.M.\n",
                         vendor="Default string\n")
            info = identity.computer_identity(sys_root=root,
                                              hostname="tower")
        self.assertEqual(info["model"], "")
        self.assertEqual(info["label"], "tower")

    def test_label_falls_back_to_model_then_generic(self):
        with tempfile.TemporaryDirectory() as root:
            make_sysroot(root, product="OptiPlex 7010\n")
            info = identity.computer_identity(sys_root=root, hostname="")
        self.assertEqual(info["label"], "OptiPlex 7010")
        with tempfile.TemporaryDirectory() as root:
            info = identity.computer_identity(sys_root=root, hostname="")
        self.assertEqual(info["label"], "This machine")

    def test_fields_are_capped_and_printable(self):
        long_name = "host\x00name\n" + "x" * 100
        info = identity.computer_identity(sys_root="/nonexistent",
                                          hostname=long_name)
        self.assertLessEqual(len(info["hostname"]), 63)
        self.assertTrue(all(ch.isprintable() for ch in info["hostname"]))

    def test_missing_sysfs_is_not_an_error(self):
        info = identity.computer_identity(sys_root="/nonexistent",
                                          hostname="xps16")
        self.assertEqual(info["model"], "")
        self.assertEqual(info["manufacturer"], "")
        self.assertEqual(info["label"], "xps16")


if __name__ == "__main__":
    unittest.main()
