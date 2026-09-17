"""mDNS reverse lookups: LAN hostnames without a DNS server.

Plain PTR lookups only work when a resolver knows the zone; home devices
announce names over multicast DNS instead. This sends one tiny PTR question
per host to the mDNS multicast group and collects answers inside a short
window. Everything is bounded: packet count, packet size, pointer depth,
and wall clock.
"""

import socket
import struct
import time


MDNS_ADDR = "224.0.0.251"
MDNS_PORT = 5353
_WINDOW = 1.2
_MAX_PACKETS = 512
_MAX_PACKET = 9000
_MAX_NAME = 63


def _encode_name(name):
    out = bytearray()
    for label in name.split("."):
        blob = label.encode("ascii", "strict")[:63]
        out.append(len(blob))
        out += blob
    out.append(0)
    return bytes(out)


def _read_name(buf, offset, depth=0):
    """(name, next_offset) with DNS compression-pointer following."""
    labels = []
    jumped = False
    next_offset = offset
    pos = offset
    while depth < 24:
        if pos >= len(buf):
            raise ValueError("name runs past packet end")
        length = buf[pos]
        if length & 0xC0 == 0xC0:
            if pos + 1 >= len(buf):
                raise ValueError("truncated compression pointer")
            if not jumped:
                next_offset = pos + 2
                jumped = True
            pos = ((length & 0x3F) << 8) | buf[pos + 1]
            depth += 1
            continue
        if length == 0:
            return ".".join(labels), (next_offset if jumped else pos + 1)
        pos += 1
        if pos + length > len(buf):
            raise ValueError("truncated label")
        labels.append(buf[pos:pos + length].decode("utf-8", "replace"))
        pos += length
    raise ValueError("compression pointer loop")


def _query_packet(reverse_name):
    """A single-question PTR query; class QU asks for a unicast reply."""
    return (struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0)
            + _encode_name(reverse_name)
            + struct.pack(">HH", 12, 0x8001))


def parse_answers(buf, wanted):
    """{ip: hostname} for PTR answers matching wanted {reverse_name: ip}."""
    found = {}
    if len(buf) < 12:
        return found
    try:
        _id, _flags, qdcount, ancount, _ns, _ar = struct.unpack(">HHHHHH", buf[:12])
    except struct.error:
        return found
    pos = 12
    try:
        for _ in range(min(qdcount, 64)):
            _name, pos = _read_name(buf, pos)
            pos += 4
        for _ in range(min(ancount, 128)):
            name, pos = _read_name(buf, pos)
            if pos + 10 > len(buf):
                break
            rtype, _rclass, _ttl, rdlen = struct.unpack(">HHIH", buf[pos:pos + 10])
            if pos + 10 + rdlen > len(buf):
                break
            if rtype == 12 and name in wanted:
                target, end = _read_name(buf, pos + 10)
                if end == pos + 10 + rdlen and target:
                    ip = wanted[name]
                    clean = target.rstrip(".")
                    if len(clean) <= _MAX_NAME:
                        found.setdefault(ip, clean)
            pos += 10 + rdlen
    except (ValueError, struct.error):
        pass
    return found


def _reverse_name(ip):
    return ".".join(reversed(ip.split("."))) + ".in-addr.arpa"


def mdns_reverse_names(ips, deadline, sender=None):
    """{ip: hostname} for up to 64 addresses, inside one short window.

    The window is capped at _WINDOW regardless of the caller's deadline:
    on a quiet LAN mDNS answers arrive in tens of milliseconds, and sitting
    on the socket for seconds buys nothing. sender injectable for tests:
    sender(sock, packet) per query.
    """
    out = {}
    ips = list(ips)[:64]
    if not ips:
        return out
    deadline = min(deadline, time.monotonic() + _WINDOW)
    wanted = {_reverse_name(ip): ip for ip in ips}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("", MDNS_PORT))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                            socket.inet_aton(MDNS_ADDR) + socket.inet_aton("0.0.0.0"))
        except OSError:
            # Something (avahi, resolved) already holds 5353. The QU bit in
            # each question still asks responders for a unicast reply to our
            # ephemeral port, so we simply listen without the group.
            pass
        sock.settimeout(0.15)
        for reverse in wanted:
            packet = _query_packet(reverse)
            try:
                if sender is not None:
                    sender(sock, packet)
                else:
                    sock.sendto(packet, (MDNS_ADDR, MDNS_PORT))
            except OSError:
                continue
        received = 0
        while time.monotonic() < deadline and len(out) < len(wanted):
            try:
                buf, _addr = sock.recvfrom(_MAX_PACKET)
            except socket.timeout:
                continue
            except OSError:
                break
            received += 1
            if received > _MAX_PACKETS:
                break
            out.update(parse_answers(buf, wanted))
        return out
    finally:
        sock.close()
