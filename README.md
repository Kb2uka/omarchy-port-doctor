# Port Doctor

A native Omarchy bar plugin that turns one header icon into a full network
instrument: **who is on your network**, **what is open**, and **what is
talking to what**.

Click the bar icon and Port Doctor opens a proper application window:

- **Network Map** — a gateway-centered topology of every device found on
  your LAN, with per-device type icons (router, laptop, NAS, Raspberry Pi,
  printer, camera, TV, phone, console, IoT), status dots, and a full device
  table underneath. Map, List, and Table presentations.
- **Devices** — the complete table: IP, device name, vendor, open ports as
  compact pills, last-seen time, and online status, with quick filters.
- **Open Ports** — every listening port found, sorted and class-colored.
- **Services** — the network aggregated by service: which hosts run ssh,
  dns, http, smb, and so on.
- **This Mac** — your machine's own listening sockets (with bind scope:
  LAN-reachable or loopback-only) and every live connection with process
  names and resolved peers.
- **Vulnerabilities** — honest exposure observations from the connect scan
  (plaintext telnet, LAN-reachable databases, web admin panels), each with
  its evidence. Not a CVE audit.
- **History** — this session's scans.
- **Settings** — scan profile (Standard or Quick) and privacy notes.

Search filters everything live. Device names come from DNS PTR records and
the devices' own mDNS announcements, so hosts show as names, not bare IPs.

## Install

```
omarchy plugin add https://github.com/Kb2uka/omarchy-port-doctor --enable
```

The icon appears in the bar automatically after install; click it to open
the window. Right-click the icon to rescan immediately.

## How it works

A small read-only scanner (Python standard library only) derives the scan
range from your own network interfaces — never from user input — and only
ever touches private (RFC 1918) and link-local addresses. Hosts are found
with ordinary TCP connect attempts against a fixed list of common service
ports; a completed or refused connection marks a host alive, and no
application data is ever sent or received. Names resolve via reverse DNS
and bounded mDNS queries on the local link. If the machine has no private
IPv4 interface, no probe traffic is sent at all and only the kernel's
neighbor table is shown.

The machine view parses `/proc/net/{tcp,tcp6,udp,udp6}` and attributes
sockets to processes owned by your account; sockets owned by other accounts
or the system are shown without a process name.

Everything is bounded: at most 256 probe targets, a fixed port list, capped
concurrency, sub-second per-connect timeouts, and an absolute scan deadline,
so a large or filtered network cannot hang the UI. The network rescans on a
slow clock (default 5 minutes, adjustable 30 s – 1 h in the plugin settings)
and the machine view refreshes live while the window is open.

## Requirements

- Omarchy with Hyprland
- iproute2 (`ip`, part of every Arch/Omarchy install)
- Python 3.11+ (standard library only; ships with Omarchy)

## Uninstall

```
omarchy plugin remove kb2uka.port-doctor
```
