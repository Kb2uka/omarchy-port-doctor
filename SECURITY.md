# Security

Port Doctor observes the local network as the logged-in user. The Omarchy
shell does not sandbox plugins, so install only source you trust.

## Boundaries

- Scan targets are derived from the machine's own interface configuration
  (`ip -j addr/route/neigh`), never from free-text user input. Only private
  (RFC 1918, CGNAT) IPv4 addresses are ever probed, and every connect
  re-checks that rule. Prefixes wider than /24 are collapsed to the /24
  holding the machine's own address, capped at 256 probe targets.
  Link-local (169.254/16) neighbors may be displayed from the neighbor
  table but are never probed. When no private interface exists at all, zero
  probes and zero name queries are sent, and the passive neighbor-table view
  is capped at 1024 entries.
- Optional whole-network source: if the user hand-creates
  `~/.config/port-doctor/unifi.env` (or `~/.config/unifi/env`) with
  `UNIFI_HOST` and `UNIFI_API_KEY`, Port Doctor makes read-only HTTPS
  queries (`stat/sta`, `rest/networkconf`) to that UniFi controller and
  merges its client census. The host must be a private IPv4 literal —
  hostnames and public addresses are rejected. Redirects are refused and
  environment proxies are disabled, so requests stay on the configured
  controller connection. Controller-reported hosts outside the
  local subnet are capped (128) and probed with the same bare connects,
  the same allowlist re-check, and the same absolute deadline; clients
  beyond that cap are simply not shown. Responses are size-capped and the
  key is never logged or rendered, including in error messages. TLS
  certificate verification is enabled by default. For a self-signed
  controller, configure a certificate with an IP-address Subject Alternative
  Name matching `UNIFI_HOST`, and trust its certificate or issuing CA through
  the system trust store before connecting. Importing a DNS-name-only
  certificate is insufficient: it must be replaced with one containing that
  IP address. Existing configurations that omitted `UNIFI_VERIFY_TLS` now
  require these certificate checks to succeed. An explicit
  `UNIFI_VERIFY_TLS=false` retains compatibility
  with an untrusted self-signed certificate, but permits an attacker on the
  network to impersonate the controller and obtain the API key; a private
  address alone does not authenticate a peer. Use a read-only API key.
  The credential file (`~/.config/port-doctor/unifi.env`,
  `~/.config/unifi/env`, or `$PORT_DOCTOR_UNIFI_CONFIG`) is opened
  without following symlinks (`O_NOFOLLOW`, `O_NONBLOCK`); the opened
  descriptor is fstat'd and must be a regular file owned by the current
  user with no group or other permission bits before any bytes are read.
  Missing files are skipped. Unsafe files are refused with an error that
  does not include the key; a later private file may still be used. Port
  Doctor never creates, overwrites, or changes mode of the file. If a
  file was ever world-readable, rotate the key and `chmod 600` it. In
  passive mode the controller is never contacted.
- Probing is a bare TCP connect: no application bytes are sent or received,
  no banners are read, no raw sockets are used. The only UDP the plugin
  crafts itself is one small mDNS PTR question per nameless host to the
  fixed local multicast group (224.0.0.251:5353); answers are parsed with
  strict bounds. Separately, reverse-DNS hostname lookups are performed by
  the system's own resolver (ordinary DNS through the configured resolver,
  exactly like any name lookup on the machine). In passive mode (no private
  interface), no packets or queries are sent at all.
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
