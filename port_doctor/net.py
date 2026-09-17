"""Local network topology via iproute2. Read-only calls with hard bounds."""

import ipaddress
import json
import select
import subprocess
import time


_IP = "/usr/bin/ip"
_MAX_OUTPUT = 4 * 1024 * 1024
_TIMEOUT = 3.0
MAX_SCAN_HOSTS = 256
# Wider prefixes are collapsed to the /24 holding our own address: scanning a
# /16 would multiply probe traffic by 256 for no realistic home-network gain.
SCAN_PREFIX_FLOOR = 24


def _run_capped(argv, timeout=_TIMEOUT, cap=_MAX_OUTPUT):
    """Run argv, returning stdout capped at cap bytes or None on failure.

    Reads incrementally: a runaway writer trips the cap and is killed
    instead of buffering unboundedly first, and a trickler cannot stretch
    the run past one absolute deadline.
    """
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return None
    deadline = time.monotonic() + timeout
    chunks = []
    total = 0
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                proc.kill()
                return None
            ready, _, _ = select.select([proc.stdout], [], [], remaining)
            if not ready:
                proc.kill()
                return None
            data = proc.stdout.read1(min(65536, cap + 1 - total))
            if not data:
                break
            chunks.append(data)
            total += len(data)
            if total > cap:
                proc.kill()
                return None
        proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        if proc.returncode != 0:
            return None
        return b"".join(chunks)
    except (OSError, subprocess.TimeoutExpired):
        proc.kill()
        return None
    finally:
        proc.stdout.close()
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def _ip_json(*args):
    blob = _run_capped([_IP, "-j", "-4", *args])
    if blob is None:
        return None
    try:
        return json.loads(blob.decode("utf-8", "replace"))
    except ValueError:
        return None


def interfaces():
    """[{ifname, addrs:[{local, prefixlen}]}] for up, non-loopback IPv4 ifaces."""
    data = _ip_json("addr", "show")
    if not isinstance(data, list):
        return []
    out = []
    for entry in data[:64]:
        if not isinstance(entry, dict):
            continue
        flags = entry.get("flags") or []
        if "LOOPBACK" in flags or "UP" not in flags:
            continue
        ifname = str(entry.get("ifname") or "")[:32]
        addrs = []
        for info in (entry.get("addr_info") or [])[:8]:
            if not isinstance(info, dict) or info.get("family") != "inet":
                continue
            try:
                local = str(ipaddress.IPv4Address(str(info.get("local") or "")))
                prefixlen = int(info.get("prefixlen"))
                if not 0 <= prefixlen <= 32:
                    continue
            except (ValueError, TypeError):
                continue
            addrs.append({"local": local, "prefixlen": prefixlen})
        if ifname and addrs:
            out.append({"ifname": ifname, "addrs": addrs})
    return out


def default_gateways():
    """[{gateway, dev}] from the IPv4 default routes."""
    data = _ip_json("route", "show", "default")
    if not isinstance(data, list):
        return []
    out = []
    for entry in data[:8]:
        if not isinstance(entry, dict):
            continue
        gateway = entry.get("gateway")
        dev = entry.get("dev")
        if not gateway or not dev:
            continue
        try:
            gateway = str(ipaddress.IPv4Address(str(gateway)))
        except ValueError:
            continue
        out.append({"gateway": gateway, "dev": str(dev)[:32]})
    return out


def neighbors():
    """{ip: {mac, dev, state}} from the kernel neighbor (ARP) table."""
    data = _ip_json("neigh", "show")
    if not isinstance(data, list):
        return {}
    out = {}
    for entry in data[:1024]:
        if not isinstance(entry, dict):
            continue
        dst = entry.get("dst")
        if not dst:
            continue
        try:
            ip = str(ipaddress.IPv4Address(str(dst)))
        except ValueError:
            continue
        states = entry.get("state") or []
        state = str(states[0]).upper() if states else ""
        out[ip] = {
            "mac": str(entry.get("lladdr") or "").lower()[:17],
            "dev": str(entry.get("dev") or "")[:32],
            "state": state[:16],
        }
    return out


def scannable(ip):
    """True only for addresses a LAN scan may legitimately touch.

    An explicit allowlist, not `is_private`: Python counts documentation
    ranges (192.0.2.0/24, 203.0.113.0/24, …) as private, and probe traffic
    must stay inside RFC 1918, CGNAT, and link-local space only. The
    scanner derives targets from local interfaces, and this check runs
    again on every single connect as a backstop.
    """
    try:
        addr = ipaddress.IPv4Address(ip)
    except ValueError:
        return False
    return any(addr in allowed for allowed in _ALLOWED_NETWORKS)


_ALLOWED_NETWORKS = tuple(
    ipaddress.IPv4Network(cidr)
    for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                 "100.64.0.0/10", "169.254.0.0/16"))


def network_window(local, prefixlen):
    """(cidr_text, [host addresses], truncated) for one interface address.

    Prefixes wider than /24 are collapsed to the /24 containing `local`;
    prefixes narrower than /24 (tiny point-to-point nets) are honored.
    """
    effective = max(int(prefixlen), SCAN_PREFIX_FLOOR)
    truncated = effective != int(prefixlen)
    network = ipaddress.IPv4Network(f"{local}/{effective}", strict=False)
    hosts = []
    for addr in network.hosts():
        if len(hosts) >= MAX_SCAN_HOSTS:
            truncated = True
            break
        hosts.append(str(addr))
    if not hosts:
        # /31 and /32 report no hosts(); the interface address itself stands in.
        hosts = [str(local)]
    return str(network), hosts, truncated
