# cmciii_temp: Temperature monitoring for Rittal LCP devices via SNMP.
# Reads temperature sensors and grades them against warn/crit levels.

def _build_oid(base, suffix):
    if not suffix:
        return base
    return base + "." + suffix

def _split_idx(oid, base):
    # index is the part of oid after base + "."
    prefix = base + "."
    if oid.startswith(prefix):
        return oid[len(prefix):]
    return ""

def _parse_temp_rows(res):
    # snmpwalk -Oqn output: "<OID> <value>" per line. Value may be quoted.
    rows = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        raw = line[sp + 1:].strip()
        # strip the leading type/value formatting if present
        if raw.startswith('"') and raw.endswith('"'):
            raw = raw[1:-1]
        rows[oid] = raw
    return rows

def _get_scalar(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    v = res.stdout.strip()
    if v.startswith('"') and v.endswith('"'):
        v = v[1:-1]
    return v

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for the Rittal LCP device via sysDescr.
        descr = _get_scalar(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
        if descr == None or not descr.startswith("Rittal LCP"):
            return {"changed": False, "msg": "not a Rittal LCP device", "data": {"discovery": []}}

        # Table 8.3.2 Temperature. We model the sensor table by walking the
        # DescName column (0) and indexing other columns by the numeric index.
        # Rittal temp table base OID: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2
        base = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
        # column 2 = DescName (string), column 8 = Value (temperature, x10 int)
        desc_rows = _parse_temp_rows(ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-OvQ", host, base + ".2"],
            mutates=False,
        ))
        val_rows = _parse_temp_rows(ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-OvQ", host, base + ".8"],
            mutates=False,
        ))
        # Only sensors that actually report a Value are discovered.
        out = []
        for oid, _v in val_rows.items():
            idx = _split_idx(oid, base + ".8")
            desc_oid = _build_oid(base + ".2", idx)
            desc_name = desc_rows.get(desc_oid, "").strip()
            # The item used by the check is the numeric id; we surface a
            # readable item when a description is available.
            item = desc_name if desc_name else idx
            out.append({
                "item": item,
                "params": {"_item_key": idx, "warn": 60, "crit": 70},
                "metrics": ["temperature"],
            })
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(out), "data": {"discovery": out}}

    # CHECK MODE
    item = params.get("item", "")
    idx = params.get("_item_key", item)
    warn = params.get("warn", 60)
    crit = params.get("crit", 70)

    base = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
    # Value (temperature *10, integer)
    val_oid = _build_oid(base + ".8", idx)
    val_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, val_oid], mutates=False)
    if val_res.rc != 0 or not val_res.stdout.strip():
        return {
            "changed": False,
            "msg": "no temperature sensor found for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw_val = val_res.stdout.strip()
    if raw_val.startswith('"') and raw_val.endswith('"'):
        raw_val = raw_val[1:-1]
    if not raw_val.lstrip("-").isdigit():
        return {
            "changed": False,
            "msg": "unexpected value for item %s: %s" % (item, raw_val),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    v = int(raw_val)
    try_val = float(v) / 10.0

    # Optional description for the summary line.
    desc_oid = _build_oid(base + ".2", idx)
    desc = _get_scalar(ctx, host, community, desc_oid)
    if desc != None:
        desc = desc.replace("Temperature", "").strip()
    else:
        desc = ""

    if try_val >= crit:
        state = "CRIT"
    elif try_val >= warn:
        state = "WARN"
    else:
        state = "OK"

    summary = "%s %f C" % (desc + " " if desc else "", try_val)
    return {
        "changed": False,
        "msg": summary.strip(),
        "data": {
            "state": state,
            "metrics": {"temperature": try_val},
            "details": "",
        },
    }