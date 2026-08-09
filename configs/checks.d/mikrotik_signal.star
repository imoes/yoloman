def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn, crit = params.get("levels_lower", (80.0, 70.0))

    base = ".1.3.6.1.4.1.14988.1.1.1.1.1"
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    detect_oid = ".1.3.6.1.4.1.14988.1"

    # Detect: is this a MikroTik device?
    det = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, detect_oid], mutates=False)
    if det.rc != 0:
        return {"changed": False, "msg": "host is not a MikroTik device",
                "data": {"discovery": []}}

    if params.get("_discover"):
        # Walk all three columns by shared index.
        networks = _walk(ctx, community, host, base + ".5.2")
        strengths = _walk(ctx, community, host, base + ".4.2")
        modes = _walk(ctx, community, host, base + ".8.2")

        # Correlate by index; item = network value.
        rows = []
        for idx in sorted(networks.keys()):
            net = networks[idx]
            if net == "":
                continue
            rows.append({
                "item": net,
                "params": {"levels_lower": [80.0, 70.0]},
                "metrics": ["quality"],
            })
        return {"changed": False,
                "msg": "discovered %d signal services" % len(rows),
                "data": {"discovery": rows}}

    # CHECK MODE
    item = params.get("item", "")
    networks = _walk(ctx, community, host, base + ".5.2")
    strengths = _walk(ctx, community, host, base + ".4.2")
    modes = _walk(ctx, community, host, base + ".8.2")

    idx_of = None
    for idx in sorted(networks.keys()):
        if networks[idx] == item:
            idx_of = idx
            break

    if idx_of == None:
        return {"changed": False, "msg": "Network not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    strength = _strconv(strengths.get(idx_of, "0"))
    mode = modes.get(idx_of, "")

    quality = 0
    if strength <= -50 or strength >= -100:
        quality = 2 * (strength + 100)
    quality = min(quality, 100)

    if quality <= crit:
        state = "CRIT"
    elif quality <= warn:
        state = "WARN"
    else:
        state = "OK"

    infotext = "Signal quality %d%% (%ddBm). Mode is: %s" % (quality, strength, mode)
    return {"changed": False, "msg": infotext,
            "data": {"state": state,
                     "metrics": {"quality": float(quality)},
                     "details": ""}}


def _walk(ctx, community, host, column_oid):
    """Walk a single column OID; return {index: value} mapping."""
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid], mutates=False)
    out = {}
    if res.rc != 0:
        return out
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(column_oid) + 1:]
        if idx == "":
            continue
        out[idx] = _strip_val(val)
    return out


def _strip_val(val):
    """Remove a leading \"<TYPE>: \" prefix and surrounding quotes if present."""
    v = val
    if v.startswith("\""):
        v = v[1:]
    if v.endswith("\""):
        v = v[:-1]
    return v


def _strconv(s):
    if s.lstrip("-").isdigit():
        return int(s)
    return 0