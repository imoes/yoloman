# Linux network interface check (read-only).
#
# Ported from cmk.plugins.network.agent_based.lnx_if, adapted for an agent that
# does not ship ethtool. Where the Checkmk agent shells out to ethtool for speed
# and link state, this reads the kernel's own /sys/class/net, which is always
# present and needs no extra package:
#   type      ARPHRD number — 772 is loopback, 1 is ethernet (authoritative,
#             where Checkmk guesses "24 if name==lo else 6")
#   operstate up / down / unknown
#   carrier   1 / 0  (fallback when operstate is "unknown", e.g. some virtio NICs)
#   speed     link speed in Mbit/s, or -1 when the driver cannot report it
#             (virtio, bonds) — genuinely unknown, not an error
#
# Discovery mirrors Checkmk's defaults (lib/interfaces.DISCOVERY_DEFAULT_PARAMETERS):
# only real ports (loopback porttype 24 excluded) that are currently up
# (portstates ["1"]), and never docker veth* pairs.

LOOPBACK_ARPHRD = "772"

def _read(ctx, path):
    """One /sys value, stripped; "" when the file is absent (rc != 0)."""
    res = ctx.run(["cat", path], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _iface_names(ctx):
    res = ctx.run(["ls", "/sys/class/net"], mutates=False)
    if res.rc != 0:
        return []
    return sorted([n for n in res.stdout.split() if n])

def _oper_up(operstate, carrier):
    # operstate is the direct answer where the driver sets it; virtio leaves it
    # "unknown", so fall back to carrier (1 = link present).
    if operstate == "up":
        return True
    if operstate == "down":
        return False
    return carrier == "1"

def _monitored(ctx, name):
    """A real, up port — the set Checkmk would discover by default."""
    if name.startswith("veth"):
        return False
    if _read(ctx, "/sys/class/net/%s/type" % name) == LOOPBACK_ARPHRD:
        return False
    operstate = _read(ctx, "/sys/class/net/%s/operstate" % name)
    carrier = _read(ctx, "/sys/class/net/%s/carrier" % name)
    return _oper_up(operstate, carrier)

def _speed_label(mbit):
    # Integer-only formatting: Starlark's % rejects %.1f, and speeds are whole
    # Mbit/s anyway. -1 (or 0) means the driver does not report a speed.
    if mbit <= 0:
        return "speed unknown"
    if mbit >= 1000 and mbit % 1000 == 0:
        return "%d Gbit/s" % (mbit // 1000)
    if mbit >= 1000:
        return "%d Mbit/s" % mbit
    return "%d Mbit/s" % mbit

def _dev_counters(ctx, item):
    """in/out octets etc. for one interface from /proc/net/dev."""
    res = ctx.run(["cat", "/proc/net/dev"], mutates=False)
    for line in res.stdout.splitlines():
        stripped = line.strip()
        colon = stripped.find(":")
        if colon <= 0:
            continue
        if stripped[:colon].strip() != item:
            continue
        f = stripped[colon + 1:].split()
        if len(f) >= 16:
            return [int(x) for x in f]
    return None

def main(ctx, params):
    if params.get("_discover"):
        out = []
        for name in _iface_names(ctx):
            if not _monitored(ctx, name):
                continue
            out.append({
                "item": name,
                "params": {"target_states": ["up"]},
                "metrics": ["in_octets", "out_octets", "in_err", "out_err", "in_disc", "out_disc", "speed"],
            })
        return {"changed": False, "msg": "discovered %d interfaces" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if _read(ctx, "/sys/class/net/%s/type" % item) == "":
        return {"changed": False, "msg": "interface %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    operstate = _read(ctx, "/sys/class/net/%s/operstate" % item)
    carrier = _read(ctx, "/sys/class/net/%s/carrier" % item)
    up = _oper_up(operstate, carrier)

    speed_raw = _read(ctx, "/sys/class/net/%s/speed" % item)
    mbit = int(speed_raw) if (speed_raw.lstrip("-").isdigit()) else -1

    # A discovered-up interface that is now down is the alarm case. Target states
    # come from discovery (params.target_states); default to ["up"].
    targets = params.get("target_states", ["up"])
    state = "OK" if (("up" if up else "down") in targets) else "WARN"

    # Throughput (net_rx_bytes/net_tx_bytes) is graphed from the agent's own
    # telemetry, so it is not re-reported here. No honest SCALAR exists for an
    # interface without two samples to rate against — Checkmk shows in/out
    # utilisation, which needs state between checks we do not keep — so the
    # metrics dict is left empty rather than surfacing a raw discard counter as
    # the service's headline number (which read as a problem on an OK link).
    # State + speed live in the summary; throughput lives in the graphs.
    msg = "%s: %s, %s" % (item, "up" if up else "down", _speed_label(mbit))

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}
