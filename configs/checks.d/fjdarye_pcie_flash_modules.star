def _table_rows_to_index_map(base_oid, rows):
    out = {}
    for entry in rows:
        if type(entry) == "string":
            parts = entry.split(" ")
            if len(parts) >= 2:
                oid = parts[0]
                val = parts[1]
                if oid.startswith(base_oid + "."):
                    idx = oid[len(base_oid) + 1:]
                    out[idx] = val
    return out

def main(ctx, params):
    base = ".1.3.6.1.4.1.211.1.21.1.150.2.22.2.1"
    col_id = base + ".2"
    col_status = base + ".3"
    col_health = base + ".5"
    oid_sysid = ".1.3.6.1.2.1.1.2.0"
    sysid = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real device identity first.
    sysid_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", sysid, sysid
    ], mutates=False)
    if sysid_res.rc != 0 or sysid_res.skipped or not sysid_res.stdout:
        return {"changed": False, "msg": "no fjdarye PCIe flash module device found",
                "data": {"discovery": []}}
    sysid_val = sysid_res.stdout.strip()
    if sysid_val != ".1.3.6.1.4.1.211.1.21.1.150":
        return {"changed": False, "msg": "host does not expose the fjdarye500 device",
                "data": {"discovery": []}}

    if params.get("_discover"):
        id_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn", oid_sysid, col_id
        ], mutates=False)
        st_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn", oid_sysid, col_status
        ], mutates=False)
        hl_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn", oid_sysid, col_health
        ], mutates=False)
        if id_res.rc != 0 or st_res.rc != 0 or hl_res.rc != 0:
            return {"changed": False, "msg": "fjdarye PCIe flash module device not present",
                    "data": {"discovery": []}}

        ids = _table_rows_to_index_map(col_id, id_res.stdout.splitlines())
        statuses = _table_rows_to_index_map(col_status, st_res.stdout.splitlines())
        healths = _table_rows_to_index_map(col_health, hl_res.stdout.splitlines())

        discovery = []
        for idx in sorted(ids.keys()):
            module_id = ids[idx]
            status = statuses.get(idx, "")
            if status == "4":
                continue
            hl_raw = healths.get(idx, "")
            if not hl_raw or hl_raw == "-1":
                hl_val = 0
            else:
                hl_val = float(hl_raw) if hl_raw.replace("-", "").replace(".", "").isdigit() else 0
            entry = {
                "item": module_id,
                "params": {"health_lifetime_perc": (20.0, 15.0)},
                "metrics": ["health_lifetime_perc"],
            }
            discovery.append(entry)
        return {"changed": False, "msg": "discovered %d PCIe flash modules" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE
    item = params.get("item", "")
    warn_default = 20.0
    crit_default = 15.0
    levels = params.get("health_lifetime_perc", (warn_default, crit_default))
    warn = levels[0] if type(levels) == "tuple" and len(levels) >= 2 else warn_default
    crit = levels[1] if type(levels) == "tuple" and len(levels) >= 2 else crit_default

    # Re-probe identity to confirm the device is still here at check time.
    sysid_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", oid_sysid, sysid
    ], mutates=False)
    if sysid_res.rc != 0 or sysid_res.skipped or not sysid_res.stdout:
        return {"changed": False, "msg": "fjdarye PCIe flash module device not present",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sysid_res.stdout.strip() != ".1.3.6.1.4.1.211.1.21.1.150":
        return {"changed": False, "msg": "host does not expose the fjdarye500 device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    id_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", oid_sysid, col_id
    ], mutates=False)
    st_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", oid_sysid, col_status
    ], mutates=False)
    hl_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", oid_sysid, col_health
    ], mutates=False)
    if id_res.rc != 0 or st_res.rc != 0 or hl_res.rc != 0:
        return {"changed": False, "msg": "fjdarye PCIe flash module data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ids = _table_rows_to_index_map(col_id, id_res.stdout.splitlines())
    statuses = _table_rows_to_index_map(col_status, st_res.stdout.splitlines())
    healths = _table_rows_to_index_map(col_health, hl_res.stdout.splitlines())

    found_status = None
    found_health = 0
    for idx in sorted(ids.keys()):
        if ids[idx] == item:
            found_status = statuses.get(idx, "")
            hl_raw = healths.get(idx, "")
            if not hl_raw or hl_raw == "-1":
                found_health = 0
            else:
                found_health = float(hl_raw) if hl_raw.replace("-", "").replace(".", "").isdigit() else 0
            break

    if found_status == None:
        return {"changed": False, "msg": "no PCIe flash module item %s found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summary = ""
    state = "OK"
    if found_status == "1":
        summary = "Status: normal"
        state = "OK"
    elif found_status == "2":
        summary = "Status: alarm"
        state = "CRIT"
    elif found_status == "3":
        summary = "Status: warning"
        state = "WARN"
    elif found_status == "5":
        summary = "Status: maintenance"
        state = "OK"
    elif found_status == "6":
        summary = "Status: undefined"
        state = "UNKNOWN"
    else:
        summary = "Status: unknown"
        state = "UNKNOWN"

    metrics = {}
    details = summary
    if found_health == 0:
        # health lifetime unavailable
        summary = "Health lifetime cannot be obtained"
        metrics = {}
        details = summary
    else:
        hl_level = "OK"
        if found_health <= crit:
            hl_level = "CRIT"
        elif found_health <= warn:
            hl_level = "WARN"
        if hl_level == "CRIT":
            state = "CRIT" if state != "UNKNOWN" else state
        elif hl_level == "WARN":
            if state != "CRIT" and state != "UNKNOWN":
                state = "WARN"
        metrics = {"health_lifetime_perc": found_health}
        details = summary + ", Health lifetime: " + str(found_health) + "%"

    msg = summary
    if found_health != 0:
        msg = summary + ", Health lifetime: " + str(found_health) + "%"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}