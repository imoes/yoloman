# Translated Checkmk check: bvip_temp
# Monitors temperature sensors on Bosch VIP devices via SNMP.

def _split_first(s, sep):
    idx = s.find(sep)
    if idx == -1:
        return [s]
    return [s[:idx], s[idx + 1:]]

def _parse_oid_index(line, base_oid):
    # line looks like "<base>.<index> <value>" from snmpwalk -Oqn
    parts = line.split(" ", 1)
    if len(parts) < 2:
        return None, None
    full_oid = parts[0]
    value = parts[1]
    if len(full_oid) <= len(base_oid) + 1:
        return None, None
    # full_oid == base_oid + "." + index  (base_oid does not end with a dot)
    if full_oid[:len(base_oid) + 1] != base_oid + ".":
        return None, None
    index = full_oid[len(base_oid) + 1:]
    return index, value

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    base_oid = ".1.3.6.1.4.1.3967.1.1.7.1"
    # Discovery: walk column 1 (the label/name column), base_oid.1
    res = ctx.run(
        ["snmpwalk", "-" + ("v2c" if version == "2c" else version),
         "-c", community, "-Oqn", "-OQ", host, base_oid + ".1"],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return {
            "changed": False,
            "msg": "not a BVIP device (SNMP walk failed)",
            "data": {"discovery": [], "host_labels": {}},
        }

    # Build index -> name map
    index_to_name = {}
    name_order = []
    for line in res.stdout.splitlines():
        idx, val = _parse_oid_index(line, base_oid + ".1")
        if idx == None or val == None:
            continue
        name = val.strip().strip('"')
        if idx not in index_to_name:
            name_order.append(idx)
        index_to_name[idx] = name

    if not index_to_name:
        return {
            "changed": False,
            "msg": "no BVIP temperature sensors found",
            "data": {"discovery": [], "host_labels": {}},
        }

    if params.get("_discover"):
        discovery = []
        for idx in name_order:
            discovery.append({
                "item": index_to_name[idx],
                "params": {"levels": (50.0, 60.0)},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    # --- Check mode: evaluate one item ---
    item = params.get("item", "")
    levels = params.get("levels", (50.0, 60.0))
    warn = levels[0] if len(levels) >= 1 else 50.0
    crit = levels[1] if len(levels) >= 2 else 60.0
    label = params.get("label", "temperature")

    # Find the index for this item's name
    target_index = None
    for idx in name_order:
        if index_to_name[idx] == item:
            target_index = idx
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "no such temperature sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch the value: snmpget base_oid.<index> (column 1 is label, column 2 is value)
    # The table uses OIDEnd() for index and column "1" for label.
    # The value column is the SAME column (1) since oids=[OIDEnd(), "1"] means base.<index> and base.<index>.1
    # Re-reading: fetch=SNMPTree(base=base_oid, oids=[OIDEnd(), "1"])
    # This fetches base_oid.<index> (OIDEnd) and base_oid.<index>.1
    # Actually OIDEnd() captures the instance, and "1" is the relative OID appended.
    # So the values are at base_oid.<index>.1
    val_oid = base_oid + "." + target_index + ".1"
    vres = ctx.run(
        ["snmpget", "-" + ("v2c" if version == "2c" else version),
         "-c", community, "-Oqv", host, val_oid],
        mutates=False,
    )
    if vres.rc != 0 or vres.skipped:
        return {
            "changed": False,
            "msg": "could not read temperature value for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = vres.stdout.strip().strip('"')
    temp_val = 0
    parsed_ok = False
    # Try integer first
    int_part = raw
    if int_part.isdigit():
        temp_val = int(int_part) / 10
        parsed_ok = True
    else:
        # Try float
        try_ok = True
        cleaned = raw
        neg = cleaned.startswith("-")
        if neg:
            cleaned = cleaned[1:]
        has_dot = False
        ok = True
        for ch in cleaned:
            if ch == ".":
                if has_dot:
                    ok = False
                    break
                has_dot = True
            elif not ch.isdigit():
                ok = False
                break
        if ok and len(cleaned) > 0:
            temp_val = float(raw) / 10
            parsed_ok = True

    if not parsed_ok:
        return {
            "changed": False,
            "msg": "could not parse temperature value: " + raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "CRIT" if temp_val >= crit else ("WARN" if temp_val >= warn else "OK")
    return {
        "changed": False,
        "msg": "%s %f C" % (item, temp_val),
        "data": {
            "state": state,
            "metrics": {"temperature": temp_val},
            "details": "BVIP sensor %s: %f C (warn<%f, crit<%f)" % (item, temp_val, warn, crit),
        },
    }