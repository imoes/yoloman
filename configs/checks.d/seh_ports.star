def _warn_for_state(state):
    return "OK"

def _port_state(status):
    # status is a string from the SEH device; map "inUse"/"owned" style values.
    # The Checkmk check does NOT define an explicit mapping; it only compares
    # status to the discovery-time value. We reproduce that exact logic.
    return status

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing first: is this an SEH device?
        sysoid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid.rc != 0:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}
        if sysoid.stdout.find(".1.3.6.1.4.1.1229.") == -1:
            return {"changed": False, "msg": "not an SEH device", "data": {"discovery": []}}

        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Walk base 1: SEH-PSRV-MIB v1.167 style
        base1 = ".1.3.6.1.4.1.1229.2.50.2.1"
        col1 = base1 + ".10"  # utnPortTag
        col2 = base1 + ".26"  # utnPortUsbOwn
        col3 = base1 + ".27"  # utnPortSlot

        # Walk base 2: SEH-MIB v2.5 style
        base2 = ".1.3.6.1.4.1.1229.5"
        col1b = base2 + ".10.2.1.10"  # utnPortTag
        col2b = base2 + ".20.2.1.7"   # utnDevOwn
        col3b = base2 + ".20.2.1.8"   # utnDevPort

        def _walk(oid):
            r = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
            if r.rc != 0 or not r.stdout.strip():
                return {}
            out = {}
            for line in r.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                entry_oid = parts[0]
                value = parts[1]
                idx = entry_oid[len(oid):]
                idx = idx[1:] if idx.startswith(".") else idx
                out[idx] = value
            return out

        tag_map = _walk(col1)
        status_map = _walk(col2)
        slot_map = _walk(col3)

        tag_map2 = _walk(col1b)
        status_map2 = _walk(col2b)
        slot_map2 = _walk(col3b)

        # Determine which base tree actually returned data.
        section = {}
        bases = [
            (tag_map, status_map, slot_map, col1, col2, col3),
            (tag_map2, status_map2, slot_map2, col1b, col2b, col3b),
        ]
        for (tmap, smap, spmap, tb, sb, spb) in bases:
            for idx in smap.keys():
                port = {}
                if idx in tmap and tmap[idx] != "":
                    port["tag"] = tmap[idx]
                if idx in smap and smap[idx] != "0":
                    port["status"] = smap[idx]
                if idx in spmap:
                    port["slot"] = spmap[idx]
                if port:
                    section[idx] = port

        out = []
        for key, port in section.items():
            st = port.get("status")
            out.append({
                "item": key,
                "params": {"status_at_discovery": st if st != None else None},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(out),
            "data": {"discovery": out},
        }

    # CHECK MODE
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    sysoid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid.rc != 0 or sysoid.stdout.find(".1.3.6.1.4.1.1229.") == -1:
        return {
            "changed": False,
            "msg": "SEH device not reachable or not an SEH device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    base1 = ".1.3.6.1.4.1.1229.2.50.2.1"
    col2 = base1 + ".26"
    col3 = base1 + ".27"
    col1 = base1 + ".10"

    base2 = ".1.3.6.1.4.1.1229.5"
    col1b = base2 + ".10.2.1.10"
    col2b = base2 + ".20.2.1.7"
    col3b = base2 + ".20.2.1.8"

    def _get(oid):
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if r.rc != 0:
            return None
        return r.stdout.strip()

    # Try base1 first for the item
    tag = _get(col1 + "." + item)
    status = _get(col2 + "." + item)
    slot = _get(col3 + "." + item)

    if tag == None and status == None:
        # Try base2
        tag = _get(col1b + "." + item)
        status = _get(col2b + "." + item)
        slot = _get(col3b + "." + item)

    if status == None and tag == None:
        return {
            "changed": False,
            "msg": "port not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = {}
    if tag != None and tag != "":
        data["tag"] = tag
    if status != None and status != "0":
        data["status"] = status
    if slot != None:
        data["slot"] = slot

    details_lines = []
    summary_parts = []
    for key in ("tag", "status"):
        if key in data:
            val = data[key]
            summary_parts.append(key.title() + ": " + val)
            details_lines.append(key.title() + ": " + val)

    discovery_status = params.get("status_at_discovery")
    if discovery_status != None and discovery_status != data.get("status"):
        summary_parts.append(
            "Status during discovery: " + (discovery_status or "unknown")
        )
        details_lines.append(
            "Status during discovery: " + (discovery_status or "unknown")
        )
        state = "WARN"
    else:
        state = "OK"

    msg = ", ".join(summary_parts)
    details = "\n".join(details_lines)
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": details},
    }