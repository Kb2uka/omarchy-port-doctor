"""mDNS packet build/parse against crafted fixtures (no multicast needed)."""

import struct
import unittest

from port_doctor import names


REVERSE = "1.4.168.192.in-addr.arpa"


def build_response():
    """One-answer mDNS response: PTR REVERSE -> pi-hole.lan, name compressed."""
    question = names._encode_name(REVERSE) + struct.pack(">HH", 12, 1)
    target = names._encode_name("pi-hole.lan")
    answer = (struct.pack(">H", 0xC00C)              # name: pointer to question
              + struct.pack(">HHIH", 12, 1, 120, len(target))
              + target)
    return (struct.pack(">HHHHHH", 0, 0x8400, 1, 1, 0, 0)
            + question + answer)


class NameCodecTests(unittest.TestCase):
    def test_encode_read_roundtrip(self):
        encoded = names._encode_name(REVERSE)
        decoded, end = names._read_name(encoded, 0)
        self.assertEqual(decoded, REVERSE)
        self.assertEqual(end, len(encoded))

    def test_compression_pointer(self):
        buf = b"\x00" * 12 + names._encode_name(REVERSE)
        pointer_at = len(buf)
        buf += struct.pack(">H", 0xC000 | 12)
        decoded, end = names._read_name(buf, pointer_at)
        self.assertEqual(decoded, REVERSE)
        self.assertEqual(end, pointer_at + 2)

    def test_compression_loop_is_rejected(self):
        buf = struct.pack(">H", 0xC000) + b"\x00" * 4
        with self.assertRaises(ValueError):
            names._read_name(buf, 0)

    def test_truncated_label_is_rejected(self):
        with self.assertRaises(ValueError):
            names._read_name(b"\x05ab", 0)


class ParseTests(unittest.TestCase):
    def test_ptr_answer_maps_back_to_ip(self):
        wanted = {REVERSE: "192.168.4.1"}
        found = names.parse_answers(build_response(), wanted)
        self.assertEqual(found, {"192.168.4.1": "pi-hole.lan"})

    def test_unrelated_answers_are_ignored(self):
        wanted = {"9.9.9.9.in-addr.arpa": "10.0.0.9"}
        self.assertEqual(names.parse_answers(build_response(), wanted), {})

    def test_garbage_is_safe(self):
        for blob in (b"", b"\x00" * 11, b"\xff" * 9000,
                     struct.pack(">HHHHHH", 0, 0, 500, 500, 0, 0)):
            self.assertEqual(names.parse_answers(blob, {REVERSE: "1.2.3.4"}), {})

    def test_query_packet_shape(self):
        packet = names._query_packet(REVERSE)
        self.assertEqual(struct.unpack(">HHHHHH", packet[:12]),
                         (0, 0, 1, 0, 0, 0))
        self.assertEqual(packet[-4:], struct.pack(">HH", 12, 0x8001))

    def test_empty_input_short_circuits(self):
        self.assertEqual(names.mdns_reverse_names([], 0), {})


if __name__ == "__main__":
    unittest.main()
