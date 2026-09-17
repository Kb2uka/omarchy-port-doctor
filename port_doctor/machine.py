"""This machine's live sockets from /proc/net. Read-only, bounded, no root.

/proc/net/{tcp,tcp6,udp,udp6} list every socket on the system to any user;
socket inode -> process attribution walks only processes owned by the
effective user, so other users' connections appear without a process name
rather than failing or needing privilege.
"""

import ipaddress
import os
import socket
import concurrent.futures as futures
import time

from . import services


_MAX_LINES = 65536
_MAX_PROCS = 8192
_MAX_FDS_PER_PROC = 2048
_MAX_COMM = 64
MAX_LISTENERS = 256
MAX_CONNECTIONS = 512
MAX_NAMES = 24
NAME_DEADLINE = 2.0

_TCP_STATES = {
    "01": "established", "02": "syn-sent", "03": "syn-recv",
    "04": "fin-wait1", "05": "fin-wait2", "06": "time-wait",
    "07": "close", "08": "close-wait", "09": "last-ack",
    "0A": "listening", "0B": "closing",
}


def _decode_ip(text, v6):
    """/proc hex address -> display string, or None for malformed input."""
    try:
        raw = bytes.fromhex(text)
    except ValueError:
        return None
    if v6:
        if len(raw) != 16:
            return None
        raw = b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4))
    else:
        if len(raw) != 4:
            return None
        raw = raw[::-1]
    try:
        return str(ipaddress.ip_address(raw))
    except ValueError:
        return None


def _parse_net_file(path, v6, proto):
    """Parse one /proc/net/{tcp,tcp6,udp,udp6} into socket dicts."""
    out = []
    try:
        with open(path, "r", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return out
    for line in lines[1:_MAX_LINES + 1]:
        parts = line.split()
        if len(parts) < 10:
            continue
        local = _decode_endpoint(parts[1], v6)
        remote = _decode_endpoint(parts[2], v6)
        if local is None or remote is None:
            continue
        try:
            inode = int(parts[9])
        except ValueError:
            inode = 0
        state_hex = parts[3].upper()
        if proto == "tcp":
            state = _TCP_STATES.get(state_hex, "state-" + state_hex.lower()[:4])
        else:
            # UDP sockets have no handshake: a zero remote means the socket
            # is simply bound and waiting, anything else is "connected".
            state = "bound" if remote[1] == 0 else "connected"
        out.append({
            "proto": proto, "state": state,
            "localIp": local[0], "localPort": local[1],
            "remoteIp": remote[0], "remotePort": remote[1],
            "inode": inode,
        })
    return out


def _decode_endpoint(text, v6):
    host, sep, port_text = text.partition(":")
    if not sep:
        return None
    ip = _decode_ip(host, v6)
    if ip is None:
        return None
    try:
        port = int(port_text, 16)
    except ValueError:
        return None
    if not 0 <= port <= 65535:
        return None
    return ip, port


def socket_owners(proc_root="/proc"):
    """{socket inode: {pid, comm}} for processes owned by the effective user.

    Other users' fd tables are normally unreadable; their sockets stay
    unattributed (shown as system-level) instead of erroring.
    """
    owners = {}
    try:
        euid = os.geteuid()
    except AttributeError:
        euid = -1
    try:
        entries = os.listdir(proc_root)
    except OSError:
        return owners
    scanned = 0
    for entry in entries:
        if not entry.isdigit():
            continue
        scanned += 1
        if scanned > _MAX_PROCS:
            break
        base = os.path.join(proc_root, entry)
        try:
            stat = os.stat(base)
            if euid >= 0 and stat.st_uid != euid:
                continue
        except OSError:
            continue
        fd_dir = os.path.join(base, "fd")
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        wanted = []
        for fd in fds[:_MAX_FDS_PER_PROC]:
            try:
                target = os.readlink(os.path.join(fd_dir, fd))
            except OSError:
                continue
            if target.startswith("socket:[") and target.endswith("]"):
                inode_text = target[8:-1]
                if inode_text.isdigit():
                    wanted.append(int(inode_text))
        if not wanted:
            continue
        comm = ""
        try:
            with open(os.path.join(base, "comm"), "r", errors="replace") as handle:
                comm = handle.read(_MAX_COMM + 1).strip()[:_MAX_COMM]
        except OSError:
            pass
        for inode in wanted:
            owners.setdefault(inode, {"pid": int(entry), "comm": comm})
    return owners


def _scope(ip):
    """Bind scope of a listening socket: who could reach it."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return "unknown"
    if addr.is_unspecified:
        return "all interfaces"
    if addr.is_loopback:
        return "loopback only"
    return "one interface"


def _remote_kind(ip, lan_prefixes):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return "unknown"
    if addr.is_loopback:
        return "loopback"
    for prefix in lan_prefixes:
        if addr in prefix:
            return "lan"
    if addr.is_private or addr.is_link_local:
        return "private"
    return "internet"


def _resolve_names(ips, deadline_s=NAME_DEADLINE):
    """PTR lookups for remote peers, bounded and droppable like scan.py's."""
    names = {}
    if not ips:
        return names
    deadline = time.monotonic() + deadline_s
    pool = futures.ThreadPoolExecutor(max_workers=8)
    try:
        pending = {pool.submit(socket.gethostbyaddr, ip): ip
                   for ip in ips[:MAX_NAMES]}
        for future, ip in pending.items():
            left = deadline - time.monotonic()
            if left <= 0:
                break
            try:
                name = future.result(timeout=min(1.0, left))[0]
            except Exception:
                continue
            name = name.rstrip(".")
            if len(name) <= 63:
                names[ip] = name
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    return names


def machine_snapshot(proc_root="/proc", resolver=None, lan_cidrs=()):
    """Listeners and live connections on this machine.

    lan_cidrs: display strings of the subnets the LAN scan considers home;
    members classify as "lan", other private peers as "private".
    """
    if resolver is None:
        resolver = _resolve_names
    sockets = []
    sockets += _parse_net_file(os.path.join(proc_root, "net", "tcp"), False, "tcp")
    sockets += _parse_net_file(os.path.join(proc_root, "net", "tcp6"), True, "tcp6")
    sockets += _parse_net_file(os.path.join(proc_root, "net", "udp"), False, "udp")
    sockets += _parse_net_file(os.path.join(proc_root, "net", "udp6"), True, "udp6")

    owners = socket_owners(proc_root)

    prefixes = []
    for cidr in lan_cidrs:
        try:
            prefixes.append(ipaddress.ip_network(cidr, strict=False))
        except ValueError:
            continue

    listeners = []
    connections = []
    for sock in sockets:
        owner = owners.get(sock["inode"])
        process = owner["comm"] if owner else ""
        pid = owner["pid"] if owner else None
        if sock["state"] in ("listening", "bound"):
            service, klass = services.describe_socket(sock["localPort"],
                                                      sock["proto"])
            listeners.append({
                "proto": sock["proto"], "port": sock["localPort"],
                "bind": sock["localIp"], "scope": _scope(sock["localIp"]),
                "process": process, "pid": pid,
                "service": service, "class": klass,
            })
        elif sock["state"] in ("close", "time-wait"):
            # time-wait corpses have no owner and say nothing about who is
            # talking right now; tcp "close" is equally transient.
            continue
        else:
            connections.append({
                "proto": sock["proto"], "state": sock["state"],
                "localIp": sock["localIp"], "localPort": sock["localPort"],
                "remoteIp": sock["remoteIp"], "remotePort": sock["remotePort"],
                "remoteKind": _remote_kind(sock["remoteIp"], prefixes),
                "process": process, "pid": pid, "remoteName": "",
            })

    listeners.sort(key=lambda l: (l["port"], l["proto"]))
    connections.sort(key=lambda c: (c["remoteKind"] != "lan",
                                    c["process"], c["remoteIp"],
                                    c["remotePort"]))

    truncated_listeners = max(0, len(listeners) - MAX_LISTENERS)
    truncated_connections = max(0, len(connections) - MAX_CONNECTIONS)
    listeners = listeners[:MAX_LISTENERS]
    connections = connections[:MAX_CONNECTIONS]

    remote_ips = sorted({c["remoteIp"] for c in connections
                         if c["remoteKind"] not in ("loopback", "unknown")})
    names = resolver(remote_ips)
    for conn in connections:
        conn["remoteName"] = names.get(conn["remoteIp"], "")

    return {
        "hostname": socket.gethostname()[:63],
        "listeners": listeners,
        "connections": connections,
        "stats": {
            "listeners": len(listeners),
            "connections": len(connections),
            "truncatedListeners": truncated_listeners,
            "truncatedConnections": truncated_connections,
        },
    }
