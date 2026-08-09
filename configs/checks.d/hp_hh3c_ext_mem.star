# Memory usage percentage check for HP/3Com devices via SNMP.
# Reproduces Checkmk check plugin hp_hh3c_ext_mem.

def _parse_snmp_table(res):
    """Parse -Oqn snmpwalk output: one line per row, '<OID>.<idx> <value>'."""
    table = {}
    for line in res.stdout.splitlines():
        if not line:
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1]
        # Index is the OID suffix after the column base OID.
        # We store entries keyed by the full OID; caller correlates by index.
        table[oid] = value
    return table

def _get_index(oid, column_base):
    """Extract the table index from a full OID given the column base OID."""
    prefix = column_base + "."
    if oid.startswith(prefix):
        return oid[len(prefix):]
    return ""

def _is_snmp_available(ctx, params):
    """Probe for the real thing: SNMP must be reachable."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "5", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    # rc 127 => snmpget not installed; rc 2 => timeout/no response
    if res.rc == 127 or res.rc != 0:
        return False
    return True

def _fetch_section(ctx, params):
    """Fetch and parse the SNMP section data, returning a Section dict."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Verify SNMP is reachable first.
    if not _is_snmp_available(ctx, params):
        return None

    # Walk the entity/ext table: .1.3.6.1.4.1.25506.2.6.1.1.1.1
    # columns: 1=index, 2=admin, 3=oper, 6=cpu, 8=mem_usage%, 10=temp, 12=mem_size(bytes)
    ext_table = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-t", "10", host, ".1.3.6.1.4.1.25506.2.6.1.1.1.1"],
        mutates=False,
    )
    if ext_table.rc != 0 and ext_table.rc != 1:
        # rc 0 = success, rc 1 = noMore (end of walk, still has data)
        return None

    ext_rows = _parse_snmp_table(ext_table)

    # Walk the entity info table: .1.3.6.1.2.1.47.1.1.1.1
    # columns: 1=index, 2=entity_name
    ent_table = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-t", "10", host, ".1.3.6.1.2.1.47.1.1.1.1"],
        mutates=False,
    )
    if ent_table.rc != 0 and ent_table.rc != 1:
        return None

    ent_rows = _parse_snmp_table(ent_table)

    # Correlate ext table columns by index.
    # Build a map: index -> {admin, oper, cpu, mem_usage, temp, mem_size}
    col_base = ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
    ent_col_base = ".1.3.6.1.2.1.47.1.1.1.1"

    # Group ext rows by index.
    by_index = {}
    for full_oid, value in ext_rows.items():
        idx = _get_index(full_oid, col_base)
        if idx == "" or idx == "1":
            # column 1 is the index itself; skip.
            continue
        colon_pos = full_oid.rfind(".")
        col_num = full_oid[colon_pos+1:]
        if col_num == "1":
            continue  # index column
        entry = by_index.get(idx, {"admin": "0", "oper": "0", "cpu": 0, "mem_usage": 0, "temp": 65535, "mem_size": 0})
        if col_num == "2":
            entry["admin"] = value
        elif col_num == "3":
            entry["oper"] = value
        elif col_num == "6":
            entry["cpu"] = int(value) if value.lstrip("-").isdigit() else 0
        elif col_num == "8":
            entry["mem_usage"] = int(value) if value.lstrip("-").isdigit() else 0
        elif col_num == "10":
            entry["temp"] = int(value) if value.lstrip("-").isdigit() else 0
        elif col_num == "12":
            entry["mem_size"] = int(value) if value.lstrip("-").isdigit() else 0
        by_index[idx] = entry

    # Build entity name lookup.
    entity_names = {}
    for full_oid, value in ent_rows.items():
        idx = _get_index(full_oid, ent_col_base)
        colon_pos = full_oid.rfind(".")
        col_num = full_oid[colon_pos+1:]
        if col_num == "2":
            entity_names[idx] = value

    # Build section: name+index -> data
    section = {}
    for idx, data in by_index.items():
        name = entity_names.get(idx, "")
        mem_total = data["mem_size"]
        if mem_total <= 0:
            continue
        # mem_used = 0.01 * mem_usage_pct * mem_total
        mem_used = 0.01 * data["mem_usage"] * mem_total
        mem_used_pct = float(data["mem_usage"])
        key = name + " " + idx
        section[key] = {
            "mem_total": mem_total,
            "mem_used": mem_used,
            "mem_used_pct": mem_used_pct,
        }

    return section

def main(ctx, params):
    if params.get("_discover"):
        section = _fetch_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "SNMP not available or section not found", "data": {"discovery": []}}
        discovery = []
        for name, data in sorted(section.items()):
            discovery.append({
                "item": name,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["memused"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode.
    item = params.get("item", "")
    section = _fetch_section(ctx, params)

    if section == None:
        return {
            "changed": False,
            "msg": "SNMP not available or section not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mem_used_pct = data["mem_used_pct"]
    levels = params.get("levels")
    if levels == None:
        warn, crit = 80.0, 90.0
    else:
        warn, crit = levels[0], levels[1]

    # upper levels: warn if >= warn, crit if >= crit
    if mem_used_pct >= crit:
        state = "CRIT"
    elif mem_used_pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    mem_used_bytes = data["mem_used"]
    mem_total_bytes = data["mem_total"]
    msg = "Usage %d%% (%d of %d bytes)" % (int(mem_used_pct), int(mem_used_bytes), int(mem_total_bytes))

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"memused": mem_used_pct},
            "details": "",
        },
    }