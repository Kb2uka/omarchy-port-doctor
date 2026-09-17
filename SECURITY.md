# Security

Port Doctor observes the local network as the logged-in user. The Omarchy
shell does not sandbox plugins, so install only source you trust.

## Boundaries

- Scan targets are derived from the machine's own interface configuration
  (`ip -j addr/route/neigh`), never from user input, files, or the network
  itself. Only private (RFC 1918, CGNAT) and link-local IPv4 addresses are
  ever probed, and every connect re-checks that rule. Prefixes wider than
  /24 are collapsed to the /24 holding the machine's own address, capped at
  256 probe targets. (When no private interface exists at all, zero probes
  are sent and the passive neighbor-table view is capped at 1024 entries.)
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
  connection counts, and name lengths are all bounded. The scan deadline is
  wall-clock; teardown of in-flight connects can add at most one connect
  timeout (0.3 s), and a panel-side watchdog terminates any scan that
  outlives its deadline.
- All network-derived text (hostnames, vendor strings, process names) is
  rendered as plain text only, capped in length at collection.
- Reverse DNS lookups are bounded, droppable, and abandoned at the scan
  deadline rather than retried.

## Privacy

Scan results and connection data are never stored, exported, or transmitted
by this plugin: no telemetry, no persistence, nothing leaves the machine by
its own design. One caveat in plain terms: reverse-DNS (PTR) lookups used to
name hosts and peers are ordinary DNS queries, so the system's configured
resolver sees the addresses being named, exactly as with any name lookup the
machine performs. The panel displays your network's layout and this
machine's live peers on screen; treat screenshots accordingly.

## Limits

This is a visibility tool, not a security monitor. A filtered host can be
present and invisible; a connect scan shows a curated port list, not all
65,535 ports; process attribution covers the installing account, so
system-owned sockets appear without a process name.

Please report suspected vulnerabilities using this repository's private
security reporting feature when available. Do not publish personal reports
or exploit details in an ordinary issue.
