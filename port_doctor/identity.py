"""This machine's own name and model, straight from the kernel.

Every other host gets named from what the network says about it; this
machine names itself: the kernel hostname plus the DMI product name and
vendor burned into the firmware (say "xps16", "XPS 16 DA16260", "Dell
Inc."). Everything here is a bounded read of local sysfs, never a
subprocess, and every field is cleaned and capped before the UI sees it.
"""

import os
import socket


_MAX_FIELD = 63
# Firmware strings that mean "the vendor never filled this in"; an empty
# model is more honest than parroting placeholder text.
_JUNK_MODELS = {"to be filled by o.e.m.", "default string",
                "system product name", "none", "unknown"}


def _clean(text):
    """One display-safe line: printable characters only, length-capped."""
    out = "".join(ch for ch in str(text).strip() if ch.isprintable())
    return out[:_MAX_FIELD].strip()


def _read(path):
    try:
        with open(path, "r", errors="replace") as handle:
            return _clean(handle.read(128))
    except OSError:
        return ""


def computer_identity(sys_root="/sys", hostname=None):
    """{"hostname", "model", "manufacturer", "label"} for this machine.

    label is what the UI should call the machine: the hostname when there
    is one, else the model, else an honest "This machine".
    """
    if hostname is None:
        try:
            hostname = socket.gethostname()
        except OSError:
            hostname = ""
    dmi = os.path.join(sys_root, "class", "dmi", "id")
    model = _read(os.path.join(dmi, "product_name"))
    if model.lower() in _JUNK_MODELS:
        model = ""
    if not model:
        # ARM boards (Pi et al.) have no DMI; the device tree names them.
        model = _read(os.path.join(
            sys_root, "firmware", "devicetree", "base", "model"))
    hostname = _clean(hostname)
    return {
        "hostname": hostname,
        "model": model,
        "manufacturer": _read(os.path.join(dmi, "sys_vendor")),
        "label": hostname or model or "This machine",
    }
