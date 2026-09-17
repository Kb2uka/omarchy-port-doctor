"""Bounded TCP connect scan of the local subnet.

Pure standard library. The scan is read-only in network terms too: a TCP
connect attempt either completes or is refused, and no application data is
ever sent or received. Targets come only from the host's own private
interfaces, every connect re-checks net.scannable, the pool, timeouts, and
an absolute deadline bound the whole run.
"""

import concurrent.futures as futures
import errno
import socket
import time

from . import classify, names, net, services


CONNECT_TIMEOUT = 0.3
SCAN_DEADLINE = 11.0
NAME_DEADLINE = 1.5
THREADS = 128
NAME_THREADS = 16
MAX_NAMES = 64
MAX_PORTS_PER_HOST = 64
_MAX_NAME = 63


def connect_ms(ip, port, timeout):
    """("open"|"closed"|"filtered", milliseconds) for one TCP connect.

    "closed" (RST) still proves the host exists, so liveness treats it as
    an answer; only a silent host counts as absent.
    """
    if not net.scannable(ip):
        return "filtered", 0.0
    started = time.monotonic()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.settimeout(max(0.05, timeout))
        code = sock.connect_ex((ip, port))
        ms = (time.monotonic() - started) * 1000.0
        if code == 0:
            return "open", ms
        if code == errno.ECONNREFUSED:
            return "closed", ms
        return "filtered", ms
    except (OSError, ValueError):
        return "filtered", (time.monotonic() - started) * 1000.0
    finally:
        sock.close()


def _probe_many(pairs, timeout, deadline, connector):
    """Run connector(ip, port, remaining) for each (ip, port); stop at deadline."""
    results = {}
    remaining = deadline - time.monotonic()
    if remaining <= 0 or not pairs:
        return results
    with futures.ThreadPoolExecutor(max_workers=THREADS) as pool:
        pending = {}
        for ip, port in pairs:
            left = deadline - time.monotonic()
            if left <= 0.05:
                break
            pending[pool.submit(connector, ip, port, min(timeout, left))] = (ip, port)
        try:
            for done in futures.as_completed(pending, timeout=remaining):
                ip, port = pending[done]
                try:
                    state, ms = done.result(timeout=0)
                except Exception:
                    continue
                if state != "filtered":
                    results.setdefault(ip, {})[port] = (state, ms)
        except TimeoutError:
            pass
        # Cancel whatever the deadline stranded; workers still in flight are
        # bounded by their own per-connect timeouts.
        pool.shutdown(wait=True, cancel_futures=True)
    return results


def _names_for(ips, deadline):
    """PTR lookups that can be cut short; stragglers are simply abandoned.

    The system resolver has no socket timeout, so these run on their own
    pool and anything not back by the deadline is dropped from the result.
    """
    names = {}
    remaining = deadline - time.monotonic()
    if remaining <= 0.25 or not ips:
        return names
    pool = futures.ThreadPoolExecutor(max_workers=NAME_THREADS)
    try:
        pending = {}
        for ip in ips[:MAX_NAMES]:
            pending[pool.submit(socket.gethostbyaddr, ip)] = ip
        for future, ip in pending.items():
            left = deadline - time.monotonic()
            if left <= 0:
                break
            try:
                name = future.result(timeout=min(2.0, left))[0]
            except Exception:
                continue
            name = name.rstrip(".")
            if len(name) <= _MAX_NAME:
                names[ip] = name
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    return names


def resolve_names(ips, deadline):
    """Hostnames from DNS PTR first, then multicast DNS for the gaps.

    PTR answers come from the configured resolver; mDNS hears the devices'
    own announcements on the local link. mDNS only fills addresses PTR left
    nameless, and both stages die at the shared deadline.
    """
    ptr_deadline = min(deadline, time.monotonic() + NAME_DEADLINE)
    found = _names_for(ips, ptr_deadline)
    missing = [ip for ip in ips if ip not in found]
    if missing and time.monotonic() < deadline - 0.3:
        for ip, name in names.mdns_reverse_names(missing, deadline).items():
            if len(name) <= _MAX_NAME:
                found.setdefault(ip, name)
    return found


# Best-effort OUI map of vendors common on home networks. Cosmetic only:
# unknown prefixes render as an empty vendor, never a guess.
_COMMON_OUIS = {
    # Virtualization (de-facto and registered)
    "000c29": "VMware", "005056": "VMware", "525400": "QEMU/KVM",
    "080027": "VirtualBox", "00155d": "Hyper-V",
    # Raspberry Pi
    "b827eb": "Raspberry Pi", "dca632": "Raspberry Pi", "e45f01": "Raspberry Pi",
    "2ccf67": "Raspberry Pi", "d83add": "Raspberry Pi",
    # Ubiquiti (UniFi)
    "00156d": "Ubiquiti", "002722": "Ubiquiti", "0418d6": "Ubiquiti",
    "245a4c": "Ubiquiti", "44d9e7": "Ubiquiti", "68d79a": "Ubiquiti",
    "7483c2": "Ubiquiti", "788a20": "Ubiquiti", "802aa8": "Ubiquiti",
    "b4fbe4": "Ubiquiti", "dc9fdb": "Ubiquiti", "e063da": "Ubiquiti",
    "f09fc2": "Ubiquiti", "fcecda": "Ubiquiti", "18e829": "Ubiquiti",
    "ac8ba9": "Ubiquiti", "9c05d6": "Ubiquiti", "70a741": "Ubiquiti",
    "784558": "Ubiquiti", "e43883": "Ubiquiti",
    # Apple
    "001cb3": "Apple", "3c22fb": "Apple", "a4b197": "Apple",
    "f0d1a9": "Apple", "7cd1c3": "Apple", "8c8590": "Apple",
    "f8ffc2": "Apple", "a88808": "Apple", "acbc32": "Apple",
    "147dda": "Apple", "40d32d": "Apple",
    # Google / Nest / Chromecast
    "f4f5d8": "Google", "546009": "Google", "1cf29a": "Google",
    "94eb2c": "Google", "3c28a6": "Google", "f0272d": "Google",
    "30fd38": "Google", "d8eb46": "Google",
    # Amazon / Echo / Ring
    "40b4cd": "Amazon", "44650d": "Amazon", "50dce7": "Amazon",
    "74c246": "Amazon", "a002dc": "Amazon", "fca183": "Amazon",
    # Samsung
    "3c5a37": "Samsung", "8cf5a3": "Samsung", "ece09b": "Samsung",
    "40d3ae": "Samsung", "1449e0": "Samsung", "a80600": "Samsung",
    "e49282": "Samsung", "503275": "Samsung",
    # Espressif (ESP32/ESP8266 IoT boards)
    "a4cf12": "Espressif", "246f28": "Espressif", "30aea4": "Espressif",
    "3c71bf": "Espressif", "84f3eb": "Espressif", "ac67b2": "Espressif",
    "c44f33": "Espressif", "ecfabc": "Espressif",
    # TP-Link
    "f4f524": "TP-Link", "50c7bf": "TP-Link", "5c628b": "TP-Link",
    "c025e9": "TP-Link", "34e894": "TP-Link", "30b5c2": "TP-Link",
    "14ebb6": "TP-Link", "1c3bf3": "TP-Link",
    # Netgear
    "a040a0": "Netgear", "9c3dcf": "Netgear", "c03f0e": "Netgear",
    "e0469a": "Netgear", "001b2f": "Netgear", "001e2a": "Netgear",
    # ASUS
    "d850e6": "ASUS", "0492f0": "ASUS", "ac22b1": "ASUS",
    "04d9f5": "ASUS", "2cfda1": "ASUS", "ac9e17": "ASUS",
    "f07959": "ASUS", "fc3497": "ASUS",
    # Intel
    "a434d9": "Intel", "8086f2": "Intel", "7c5cf8": "Intel",
    "48f17f": "Intel", "44af28": "Intel", "a0c589": "Intel",
    "8c8d28": "Intel", "f8633f": "Intel",
    # HP
    "fc3fdb": "HP", "40b034": "HP", "3cd92b": "HP",
    "9cb654": "HP", "d0bf9c": "HP",
    # Dell
    "d8d090": "Dell", "b083fe": "Dell", "54bf64": "Dell",
    "18a99b": "Dell", "24b6fd": "Dell", "3417eb": "Dell",
    "f48e38": "Dell", "f8cab8": "Dell",
    # Sony
    "78c881": "Sony", "fcf152": "Sony", "001a80": "Sony", "d8d43c": "Sony",
    # Nintendo
    "5c521e": "Nintendo", "58bda3": "Nintendo", "40d28a": "Nintendo",
    "8c56c5": "Nintendo", "7cbb8a": "Nintendo", "002659": "Nintendo",
    # LG
    "3ccd5d": "LG", "88c9d0": "LG", "e85b5b": "LG",
    "c4366c": "LG", "10683f": "LG",
    # Huawei
    "c8d15e": "Huawei", "ac853d": "Huawei",
    # Roku
    "ac3a7a": "Roku", "b0a737": "Roku", "b0ee7b": "Roku",
    "d83134": "Roku", "dc3a5e": "Roku", "d04d2c": "Roku",
    # Sonos
    "000e58": "Sonos", "b8e937": "Sonos", "949f3e": "Sonos",
    "5caafd": "Sonos", "7828ca": "Sonos", "347e5c": "Sonos",
    # Others
    "00e04c": "Realtek", "001a2b": "Aastra", "001132": "Synology",
    "28c2dd": "Valve", "e0b9a5": "AzureWave", "0050f2": "Microsoft",
    "245ebe": "QNAP", "008077": "Brother", "000048": "Epson",
    "000085": "Canon",
}


def vendor_of(mac):
    """Best-effort vendor for a MAC prefix; empty string when unknown."""
    key = mac.replace(":", "").replace("-", "").lower()[:6]
    if len(key) != 6:
        return ""
    return _COMMON_OUIS.get(key, "")


def _alive_from_neigh(neigh, hosts):
    """Hosts the kernel recently spoke to count as alive without a probe."""
    alive = set()
    for ip, info in neigh.items():
        if ip in hosts and info.get("state") in (
                "REACHABLE", "STALE", "DELAY", "PERMANENT"):
            alive.add(ip)
    return alive


def scan_lan(interfaces=None, gateways=None, connector=connect_ms,
             resolver=None, deadline_s=SCAN_DEADLINE, port_list=None,
             now=None):
    """Scan the local subnet; every dependency injectable for tests."""
    if resolver is None:
        resolver = resolve_names
    if port_list is None:
        port_list = services.ALL_PORTS
    started = time.monotonic()
    deadline = started + deadline_s
    if interfaces is None:
        interfaces = net.interfaces()
    if gateways is None:
        gateways = net.default_gateways()

    gateway_by_dev = {g["dev"]: g["gateway"] for g in gateways}
    primary_dev = gateways[0]["dev"] if gateways else ""

    chosen = None
    for iface in interfaces:
        for addr in iface["addrs"]:
            if not net.scannable(addr["local"]):
                continue
            rank = (iface["ifname"] != primary_dev, -addr["prefixlen"])
            if chosen is None or rank < chosen[0]:
                chosen = (rank, iface, addr)

    neigh = net.neighbors()

    network = {"cidr": "", "ifname": "", "selfIp": "",
               "gateway": "", "truncated": False, "passiveOnly": True,
               "note": ""}
    hosts = {}
    discovery_ms = 0

    if chosen is None:
        # No scannable (private/link-local) interface: refuse to send any
        # probe traffic and report only what the neighbor table already knows.
        network["note"] = "no private IPv4 interface; showing the neighbor table only"
        for ip, info in neigh.items():
            if net.scannable(ip) and info.get("state") not in ("FAILED", ""):
                hosts[ip] = {"ip": ip, "alive": True, "via": "neigh",
                             "latencyMs": None, "ports": []}
    else:
        _, iface, addr = chosen
        cidr, targets, truncated = net.network_window(addr["local"],
                                                      addr["prefixlen"])
        network = {"cidr": cidr, "ifname": iface["ifname"],
                   "selfIp": addr["local"],
                   "gateway": gateway_by_dev.get(iface["ifname"], ""),
                   "truncated": truncated, "passiveOnly": False}

        host_set = set(targets)
        alive = _alive_from_neigh(neigh, host_set)
        if network["gateway"] and net.scannable(network["gateway"]):
            alive.add(network["gateway"])
        alive.add(addr["local"])

        discovery_started = time.monotonic()
        pairs = [(ip, port) for ip in targets if ip not in alive
                 for port in services.DISCOVERY_PORTS]
        probe = _probe_many(pairs, CONNECT_TIMEOUT, deadline, connector)
        discovery_ms = int((time.monotonic() - discovery_started) * 1000)
        for ip in probe:
            alive.add(ip)

        # Discovery answers are real data: an answered port (open or refused)
        # is settled, so the full pass skips it instead of re-probing, and
        # its latency feeds the host's response time.
        scanned = {ip: dict(states) for ip, states in probe.items()}
        remaining_pairs = []
        for ip in sorted(alive):
            answered = scanned.get(ip, {})
            for port in port_list:
                if port not in answered:
                    remaining_pairs.append((ip, port))
        for ip, states in _probe_many(remaining_pairs, CONNECT_TIMEOUT,
                                      deadline, connector).items():
            scanned.setdefault(ip, {}).update(states)

        for ip in sorted(alive):
            states = scanned.get(ip, {})
            latency = None
            for state, ms in states.values():
                if latency is None or ms < latency:
                    latency = ms
            # via reflects evidence: "scan" only when a probe was answered;
            # a neighbor-table seed that stayed silent is "neigh".
            hosts[ip] = {"ip": ip, "alive": True,
                         "via": "scan" if states else "neigh",
                         "latencyMs": None if latency is None else round(latency, 1),
                         "ports": [{"port": port}
                                   for port, (state, ms) in sorted(states.items())
                                   if state == "open"][:MAX_PORTS_PER_HOST]}

    # Neighbor table again: probing just refreshed it, so MACs are warm now.
    # Merge with the pre-scan read so a flaky post-scan read costs nothing.
    neigh_after = net.neighbors()
    neigh = {**neigh, **neigh_after}
    resolved = resolver(sorted(hosts), deadline)

    out_hosts = []
    for ip in sorted(hosts, key=lambda text: tuple(int(p) for p in text.split("."))):
        info = neigh.get(ip, {})
        entry = hosts[ip]
        ports = []
        for probed in entry["ports"]:
            service, klass = services.describe(probed["port"])
            ports.append({"port": probed["port"], "proto": "tcp",
                          "service": service, "class": klass})
        assembled = {
            "ip": ip,
            "hostname": resolved.get(ip, ""),
            "mac": info.get("mac", ""),
            "vendor": vendor_of(info.get("mac", "")),
            "isSelf": ip == network["selfIp"],
            "isGateway": bool(network["gateway"]) and ip == network["gateway"],
            "via": entry["via"],
            "latencyMs": entry["latencyMs"],
            "ports": ports,
        }
        assembled["type"] = classify.classify(assembled)
        out_hosts.append(assembled)

    open_ports = sum(len(h["ports"]) for h in out_hosts)
    return {
        "network": network,
        "hosts": out_hosts,
        "stats": {
            "targets": len(targets) if chosen is not None else 0,
            "hostsUp": len(out_hosts),
            "openPorts": open_ports,
            "scanMs": int((time.monotonic() - started) * 1000),
            "discoveryMs": discovery_ms,
            "deadlineHit": time.monotonic() >= deadline,
        },
    }
