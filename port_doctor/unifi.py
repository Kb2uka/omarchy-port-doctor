"""Optional read-only census from a UniFi controller on the LAN.

A connect scan can only see its own subnet; the controller already knows
every client on every network it manages. When the user hands Port Doctor
a read-only API key, the scanner merges that census in: hosts on other
networks appear with their network name, and their TCP ports are probed
exactly like local ones (RFC 1918/CGNAT re-checked per connect, same
deadline, same caps).

Config is an env-style file the user creates by hand; Port Doctor only
ever reads it, and only these keys:

    ~/.config/port-doctor/unifi.env      (or $PORT_DOCTOR_UNIFI_CONFIG)
    UNIFI_HOST=10.0.0.1        IP literal, private space only
    UNIFI_API_KEY=...          read-only local API key
    UNIFI_SITE=default         optional
    UNIFI_VERIFY_TLS=true      optional; stock controllers self-sign,
                               so the default is false

A pre-existing ~/.config/unifi/env with the same keys is also honored.
"""

import ipaddress
import json
import os
import re
import ssl
import urllib.parse
import urllib.request

from . import net


_MAX_FIELD = 63
_MAX_CONFIG = 4096
_MAX_RESPONSE = 2 * 1024 * 1024
MAX_CLIENTS = 512
DEFAULT_SITE = "default"
_CONFIG_NAMES = ("port-doctor/unifi.env", "unifi/env")
_MAC = re.compile(r"([0-9a-f]{2}:){5}[0-9a-f]{2}")


def _clean(text):
    """One display-safe line: printable characters only, length-capped."""
    out = "".join(ch for ch in str(text).strip() if ch.isprintable())
    return out[:_MAX_FIELD].strip()


def _parse_env(text):
    """KEY=value lines with # comments; quotes and `export` tolerated."""
    out = {}
    for line in text.splitlines()[:64]:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        if key.startswith("export "):
            key = key[7:].strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            out[key] = value
    return out


def _valid_host(text):
    """The controller as a private IP literal, or None.

    Hostnames are rejected on purpose: the API key rides every request,
    and a name can be rebound to a public address. A literal that passes
    net.scannable keeps the key inside RFC 1918/CGNAT space.
    """
    try:
        addr = ipaddress.IPv4Address(str(text).strip())
    except ValueError:
        return None
    if addr.is_link_local or addr.is_unspecified or addr.is_loopback:
        return None
    return str(addr) if net.scannable(addr) else None


def load_config(paths=None, environ=None):
    """(config, error): config is None when no usable file exists.

    error describes the first file that existed but failed validation, so
    the Settings page can say why a controller was configured but ignored.
    """
    environ = os.environ if environ is None else environ
    if paths is None:
        override = environ.get("PORT_DOCTOR_UNIFI_CONFIG", "")
        home = environ.get("HOME") or os.path.expanduser("~")
        paths = ([override] if override else []) + [
            os.path.join(home, ".config", name) for name in _CONFIG_NAMES]
    first_error = None
    for path in paths:
        if not path:
            continue
        try:
            with open(path, "r", errors="replace") as handle:
                values = _parse_env(handle.read(_MAX_CONFIG))
        except OSError:
            continue
        host_text = values.get("UNIFI_HOST", "")
        key = values.get("UNIFI_API_KEY", "")[:128]
        host = _valid_host(host_text)
        if host and key:
            site = _clean(values.get("UNIFI_SITE", ""))
            return ({
                "host": host,
                "site": site or DEFAULT_SITE,
                "apiKey": key,
                "verifyTls": values.get("UNIFI_VERIFY_TLS", "").strip().lower()
                             in ("1", "true", "yes"),
            }, None)
        if first_error is None:
            if not host_text.strip():
                first_error = f"{path}: UNIFI_HOST is missing"
            elif host is None:
                first_error = (f"{path}: UNIFI_HOST must be a private IPv4 "
                               "literal")
            else:
                first_error = f"{path}: UNIFI_API_KEY is missing"
    return None, first_error


def _get_json(host, api_key, path, verify_tls, timeout, opener=None):
    """One bounded HTTPS GET against the controller; raises on failure."""
    request = urllib.request.Request("https://" + host + path,
                                     headers={"X-API-KEY": api_key})
    if opener is not None:
        response = opener(request, timeout=timeout)
    else:
        context = ssl.create_default_context()
        if not verify_tls:
            # Stock UniFi controllers serve a self-signed certificate;
            # the host guard above is what keeps the key private.
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        response = urllib.request.urlopen(request, timeout=timeout,
                                          context=context)
    with response:
        raw = response.read(_MAX_RESPONSE + 1)
    if len(raw) > _MAX_RESPONSE:
        raise ValueError("controller response over 2 MiB")
    return json.loads(raw.decode("utf-8", "replace"))


def _client(entry):
    """One stat/sta record normalized, or None when unusable."""
    if not isinstance(entry, dict):
        return None
    try:
        ip = str(ipaddress.IPv4Address(str(entry.get("ip") or "")))
    except ValueError:
        return None  # IPv6-only clients: the scanner speaks IPv4
    if not net.scannable(ip):
        return None
    name = _clean(entry.get("name") or entry.get("hostname") or "")
    mac = str(entry.get("mac") or "").lower()[:17]
    if not _MAC.fullmatch(mac):
        mac = ""
    try:
        vlan = int(entry.get("vlan"))
        if not 0 <= vlan <= 4094:
            vlan = None
    except (TypeError, ValueError):
        vlan = None
    return {"ip": ip,
            "mac": str(entry.get("mac") or "").lower()[:17],
            "name": name,
            "network": _clean(entry.get("network") or ""),
            "vlan": vlan}


def _network(entry):
    """One networkconf record normalized, or None when it has no subnet."""
    if not isinstance(entry, dict):
        return None
    try:
        subnet = ipaddress.IPv4Network(str(entry.get("ip_subnet") or ""),
                                       strict=False)
    except ValueError:
        return None
    try:
        vlan = int(entry.get("vlan"))
        if not 0 <= vlan <= 4094:
            vlan = 0
    except (TypeError, ValueError):
        vlan = 0
    return {"name": _clean(entry.get("name") or ""), "vlan": vlan,
            "subnet": str(subnet)}


def controller_census(config=None, opener=None, timeout=2.5):
    """{"configured", "host", "site", "error", "clients", "networks"}.

    Never raises: any failure lands in "error" and the scan goes on with
    whatever the local subnet reported.
    """
    out = {"configured": False, "host": "", "site": "", "error": None,
           "clients": [], "networks": []}
    if config is None:
        config, error = load_config()
        if config is None:
            out["error"] = error
            return out
    out["configured"] = True
    out["host"] = config["host"]
    out["site"] = config["site"]
    base = "/proxy/network/api/s/" + urllib.parse.quote(config["site"],
                                                        safe="")[:32]
    try:
        sta = _get_json(config["host"], config["apiKey"], base + "/stat/sta",
                        config["verifyTls"], timeout, opener)
    except Exception as error:  # TLS, HTTP, JSON: one honest string
        out["error"] = str(error)[:200]
        return out
    try:
        conf = _get_json(config["host"], config["apiKey"],
                         base + "/rest/networkconf", config["verifyTls"],
                         timeout, opener)
    except Exception:
        conf = None  # network labels are nice-to-have; clients still count

    seen = set()
    for entry in (sta.get("data") if isinstance(sta, dict) else [])[:4096]:
        client = _client(entry)
        if client is None or client["ip"] in seen:
            continue
        seen.add(client["ip"])
        out["clients"].append(client)
        if len(out["clients"]) >= MAX_CLIENTS:
            break
    if isinstance(conf, dict):
        for entry in (conf.get("data") or [])[:256]:
            network = _network(entry)
            if network is not None:
                out["networks"].append(network)
    return out


def network_for_ip(ip, networks):
    """(name, vlan) of the controller network holding ip, else ("", None)."""
    try:
        addr = ipaddress.IPv4Address(ip)
    except ValueError:
        return "", None
    for entry in networks:
        try:
            subnet = ipaddress.IPv4Network(entry["subnet"])
        except (KeyError, ValueError):
            continue
        if addr in subnet:
            return entry["name"], entry["vlan"]
    return "", None
