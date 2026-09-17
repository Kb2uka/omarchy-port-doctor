"""Curated TCP port table: port -> (service name, display class).

The scan only ever probes ports in this table. Keeping it fixed and
compile-time means no user input can steer the scanner toward arbitrary
ports, and the panel can class-color services without trusting scan output.
"""

# class vocabulary: remote, web, file, print, media, iot, db, mail, infra
PORTS = {
    21: ("ftp", "file"),
    22: ("ssh", "remote"),
    23: ("telnet", "remote"),
    25: ("smtp", "mail"),
    53: ("dns", "infra"),
    80: ("http", "web"),
    88: ("kerberos", "infra"),
    110: ("pop3", "mail"),
    111: ("rpcbind", "file"),
    139: ("netbios", "file"),
    143: ("imap", "mail"),
    389: ("ldap", "infra"),
    443: ("https", "web"),
    445: ("smb", "file"),
    465: ("smtps", "mail"),
    515: ("lpd", "print"),
    548: ("afp", "file"),
    554: ("rtsp", "media"),
    587: ("submission", "mail"),
    631: ("ipp", "print"),
    636: ("ldaps", "infra"),
    853: ("dns-tls", "infra"),
    873: ("rsync", "file"),
    993: ("imaps", "mail"),
    995: ("pop3s", "mail"),
    1883: ("mqtt", "iot"),
    2049: ("nfs", "file"),
    2323: ("telnet-alt", "iot"),
    3000: ("dev-http", "web"),
    3306: ("mysql", "db"),
    3389: ("rdp", "remote"),
    5000: ("dev-http", "web"),
    5432: ("postgres", "db"),
    5900: ("vnc", "remote"),
    5901: ("vnc-1", "remote"),
    6379: ("redis", "db"),
    7000: ("airplay", "media"),
    8000: ("http-alt", "web"),
    8008: ("cast-admin", "web"),
    8009: ("cast", "media"),
    8080: ("http-alt", "web"),
    8081: ("http-alt", "web"),
    8096: ("jellyfin", "media"),
    8443: ("https-alt", "web"),
    8883: ("mqtts", "iot"),
    8888: ("http-alt", "web"),
    9000: ("http-alt", "web"),
    9100: ("jetdirect", "print"),
    9443: ("https-alt", "web"),
    32400: ("plex", "media"),
    27017: ("mongodb", "db"),
    5357: ("wsd", "file"),
}

# Small liveness probe set: answered by routers, computers, printers, and
# most appliances, so a host rarely has to time out on every port before we
# consider it absent. A refused connection still proves the host is alive.
DISCOVERY_PORTS = [80, 443, 22, 445, 53, 8080, 631, 9100]

ALL_PORTS = sorted(PORTS)


def describe(port):
    """Best-known service label and display class for a TCP port."""
    entry = PORTS.get(port)
    if entry is None:
        return "tcp", "unknown"
    return entry[0], entry[1]
