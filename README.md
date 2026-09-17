# Port Doctor

A native Omarchy bar plugin that answers three questions about your home
network at a glance: **who is on it**, **what is open**, and **what is
talking to what**.

One icon in the header opens a two-view panel:

- **Network** — every host found on your local subnet: hostname, IP, MAC and
  vendor, response time, and its open TCP ports as color-coded service chips
  (ssh, https, smb, ipp, plex, and more). Your own machine and the gateway
  are pinned out with accent markers, hosts seen for the first time get a
  NEW pill, and Enter or a click expands any host into its full port table.
- **This Mac** — the machine under your hands: every socket listening (with
  the process owning it and whether it is reachable from the network or
  loopback only), and every live connection — process, peer, port, state,
  and whether the peer is on your LAN, another private range, or the
  internet.

## Features

- Live host discovery and a bounded TCP connect scan of a fixed list of
  common service ports
- Per-host service chips, expandable port detail, latency, MAC vendor
- This-machine view: listeners with bind scope, live connections with
  process names and reverse-resolved peers
- New-host highlighting between scans, scan-age display, keyboard
  navigation (←/→ switches views, R rescans, Enter expands, Escape closes)
- Theme-aware native UI that follows your Omarchy theme

## Install

```
omarchy plugin add https://github.com/Kb2uka/omarchy-port-doctor --enable
```

The icon appears in the bar automatically after install.

## Use

- Left-click the bar icon to open or close the panel
- Right-click the icon to rescan the network immediately
- Network view: click or press Enter on a host to expand its port table
- Arrow keys move, ←/→ switches views, R rescans, Escape closes

## How it works

A small read-only scanner (Python standard library only) derives the scan
range from your own network interfaces — never from user input — and only
ever touches private (RFC 1918) and link-local addresses. Hosts are found
with ordinary TCP connect attempts to a small fixed port list; a completed
or refused connection marks a host alive, and no application data is ever
sent or received. If the machine has no private IPv4 interface, no probe
traffic is sent at all and only the kernel's neighbor table is shown.

The machine view parses `/proc/net/{tcp,tcp6,udp,udp6}` and attributes
sockets to processes owned by your account; sockets owned by other accounts
or the system are shown without a process name.

Scans are bounded everywhere: at most 256 addresses, 64 concurrent probes,
sub-second per-connect timeouts, and an absolute scan deadline, so a large
or filtered network cannot hang the panel. The network rescans on a slow
clock (default 5 minutes, adjustable 30 s – 1 h in the plugin settings) and
the machine view refreshes live while it is open.

## Requirements

- Omarchy with Hyprland
- iproute2 (`ip`, part of every Arch/Omarchy install)
- Python 3.11+ (standard library only; ships with Omarchy)

## Uninstall

```
omarchy plugin remove kb2uka.port-doctor
```
