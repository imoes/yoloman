# Mikrotik signal check — read-only Starlark translation
# Gathers signal strength and mode via SNMP, computes quality %, yields OK/WARN/CRIT


def _parse_int(s):
    """Safely parse integer. Returns 0 if empty or non-numeric."""
    if not s:
        return 0
    if s.startswith("-"):
        rest = s[1:]
        if rest.isdigit():
            return -int(rest)
        return 0
    if s.isdigit():
        return int(s)
    return 0


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            ".1.3.6.1.4.1.14988.1.1.1.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False,
                    "msg": "discovered 0 networks",
                    "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        entries = {}  # network -> {"strength": str, "mode": str}

        for line in lines:
            line = line.strip()
            if not line:
                continue
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            val_part = line[eq_idx+1:].strip()
            colon_idx = val_part.find(": ")
            if colon_idx == -1:
                val = val_part
            else:
                val = val_part[colon_idx+2:].strip()

            # Detect OID type and network by .5.2
            if ".5.2" in oid_part:
                network = val
                entries[network] = {"strength": "", "mode": ""}
            elif ".4.2" in oid_part and len(entries) > 0:
                # Assign to last network (approximation for snmpwalk output order)
                last_key = list(entries.keys())[-1]
                entries[last_key]["strength"] = val
            elif ".8.2" in oid_part and len(entries) > 0:
                last_key = list(entries.keys())[-1]
                entries[last_key]["mode"] = val

        discovered = []
        for network, data in entries.items():
            if not network:
                continue
            discovered.append({
                "item": network,
                "params": {"levels_lower": (80.0, 70.0)},
                "metrics": ["quality"]
            })

        return {"changed": False,
                "msg": "discovered %d networks" % len(discovered),
                "data": {"discovery": discovered}}

    # CHECK mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn, crit = params.get("levels_lower", (80.0, 70.0))

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host,
        ".1.3.6.1.4.1.14988.1.1.1.1.1"
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False,
                "msg": "Network not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    entries = {}  # network -> {"strength": str, "mode": str}

    for line in lines:
        line = line.strip()
        if not line:
            continue
        eq_idx = line.find("=")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        val_part = line[eq_idx+1:].strip()
        colon_idx = val_part.find(": ")
        if colon_idx == -1:
            val = val_part
        else:
            val = val_part[colon_idx+2:].strip()

        if ".5.2" in oid_part:
            network = val
            entries[network] = {"strength": "", "mode": ""}
        elif ".4.2" in oid_part and len(entries) > 0:
            last_key = list(entries.keys())[-1]
            entries[last_key]["strength"] = val
        elif ".8.2" in oid_part and len(entries) > 0:
            last_key = list(entries.keys())[-1]
            entries[last_key]["mode"] = val

    if item not in entries:
        return {"changed": False,
                "msg": "Network not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    strength_str = entries[item].get("strength", "")
    mode_val = entries[item].get("mode", "")

    strength = _parse_int(strength_str)

    quality = 0
    if strength <= -50 or strength >= -100:
        quality = 2 * (strength + 100)
    if quality > 100:
        quality = 100

    infotext = "Signal quality %d%% (%sdBm). Mode is: %s" % (quality, str(strength), mode_val)

    state = "OK"
    if quality <= crit:
        state = "CRIT"
    elif quality <= warn:
        state = "WARN"

    return {"changed": False,
            "msg": infotext,
            "data": {"state": state,
                     "metrics": {"quality": float(quality)},
                     "details": ""}}