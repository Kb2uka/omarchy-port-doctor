# Security

Port Doctor observes the local network as the logged-in user. The Omarchy
shell does not sandbox plugins, so install only source you trust.

## Boundaries

- Scan targets are derived from the machine's own interface configuration
  (`ip -j addr/route/neigh`), never from user input, files, or the network
  itself. Only private (RFC 1918, CGNAT) and link-local IPv4 addresses are
  ever probed, and every connect re-checks that rule. Prefixes wider than
  /24 are collapsed to the /24 holding the machine's own address, capped at
  256 addresses. With no private interface, zero probe traffic is sent.
- Probing is a bare TCP connect: no application bytes are sent or received,
  no banners are read, no UDP packets are crafted, no raw sockets are used.
- No root, sudo, pkexec, setuid, capabilities, services, timers, package
  installation, downloads, or writes to the filesystem. All state lives in
  the panel's memory and disappears with it.
- Python is launched by absolute path with isolated imports (`-I -B`). The
  bundled scanner imports only its own package and the standard library.
  The two subcommands are fixed literals; there are no free-text arguments.
- Subprocess output is read incrementally with an absolute deadline and a
  byte cap. Thread pools, per-connect timeouts, host counts, port counts,
  connection counts, and name lengths are all bounded, and a panel-side
  watchdog terminates any scan that outlives its deadline.
- All network-derived text (hostnames, vendor strings, process names) is
  rendered as plain text only, capped in length at collection.
- Reverse DNS lookups are bounded, droppable, and abandoned at the scan
  deadline rather than retried.

## Privacy

Scan results and connection data never leave the machine: there is no
telemetry, no export, and no persistence. Be aware that the panel displays
your network's layout and this machine's live peers on screen.

## Limits

This is a visibility tool, not a security monitor. A filtered host can be
present and invisible; a connect scan shows a curated port list, not all
65,535 ports; process attribution covers the installing account, so
system-owned sockets appear without a process name.

Please report suspected vulnerabilities using this repository's private
security reporting feature when available. Do not publish personal reports
or exploit details in an ordinary issue.
