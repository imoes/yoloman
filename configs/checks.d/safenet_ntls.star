def _oid_suffix(oid):
    return oid[len(".1.3.6.1.4.1.12383.3.1.2") + 1:] if oid.startswith(".1.3.6.1.4.1.12383.3.1.2.") else oid

def _parse_snmp_table(base_oid, output):
    """Parse snmpwalk -Oqn output: 'OID value' per line"""
    rows = {}
    for line in output.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        idx = oid[len(base_oid) + 1:] if oid.startswith(base_oid + ".") else ""
        if idx:
            rows[idx] = val
    return rows

def _check_ntls_present(ctx, host, community, version):
    """Check if this is a SafeNet NTLS device by probing sysObjectID."""
    res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False, ""
    sysoid = res.stdout.strip()
    if not sysoid:
        return False, ""
    return sysoid.startswith(".1.3.6.1.4.1.12383") or sysoid.startswith(".1.3.6.1.4.1.8072"), sysoid

def _fetch_safenet_ntls(ctx, host, community, version):
    """Fetch the safenet_ntls SNMP table and parse into a section dict."""
    base_oid = ".1.3.6.1.4.1.12383.3.1.2"
    present, sysoid = _check_ntls_present(ctx, host, community, version)
    if not present:
        return None
    res = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, base_oid], mutates=False)
    if res.rc != 0:
        return None
    rows = _parse_snmp_table(base_oid, res.stdout)
    # OIDs 1-6 are scalar values (single row, index 1)
    if "1" not in rows:
        return None
    section = {
        "operation_status": rows.get("1", ""),
        "connected_clients": int(rows.get("2", "0")) if rows.get("2", "0").isdigit() else 0,
        "links": int(rows.get("3", "0")) if rows.get("3", "0").isdigit() else 0,
        "successful_connections": int(rows.get("4", "0")) if rows.get("4", "0").isdigit() else 0,
        "failed_connections": int(rows.get("5", "0")) if rows.get("5", "0").isdigit() else 0,
        "expiration_date": rows.get("6", ""),
    }
    return section

def _grade_levels(value, warn, crit):
    """Grade a value against upper warn/crit levels."""
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    # Discovery mode
    if params.get("_discover"):
        present, _ = _check_ntls_present(ctx, host, community, version)
        if not present:
            return {"changed": False, "msg": "not a SafeNet NTLS device", "data": {"discovery": []}}
        discovery = [
            {"item": "successful", "params": {}, "metrics": ["connections_rate"]},
            {"item": "failed", "params": {}, "metrics": ["connections_rate"]},
            {"item": "", "params": {}, "metrics": []},
            {"item": "", "params": {}, "metrics": []},
            {"item": "", "params": {}, "metrics": ["connections"]},
        ]
        return {"changed": False, "msg": "discovered NTLS Operation Status checks", "data": {"discovery": discovery}}

    # Check mode
    section = _fetch_safenet_ntls(ctx, host, community, version)
    if section == None:
        return {"changed": False, "msg": "no SafeNet NTLS device found at " + host, "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP sysObjectID does not match SafeNet NTLS"}}

    plugin = params.get("_plugin", params.get("plugin", "safenet_ntls_operation_status"))
    item = params.get("item", "")
    levels = params.get("levels", None)

    if plugin == "safenet_ntls_operation_status" or plugin == "safenet_ntls":
        status = section["operation_status"]
        if status == "1":
            return {"changed": False, "msg": "Running", "data": {"state": "OK", "metrics": {}, "details": "NTLS service is running"}}
        elif status == "2":
            return {"changed": False, "msg": "Down", "data": {"state": "CRIT", "metrics": {}, "details": "NTLS service is down"}}
        elif status == "3":
            return {"changed": False, "msg": "Unknown", "data": {"state": "UNKNOWN", "metrics": {}, "details": "NTLS operation status is unknown"}}
        else:
            return {"changed": False, "msg": "Unknown status: " + status, "data": {"state": "UNKNOWN", "metrics": {}, "details": "Unexpected NTLS operation status value"}}

    elif plugin == "safenet_ntls_expiration":
        return {"changed": False, "msg": "The NTLS server certificate expires on " + section["expiration_date"], "data": {"state": "OK", "metrics": {}, "details": "Expiration date: " + section["expiration_date"]}}

    elif plugin == "safenet_ntls_links":
        links = section["links"]
        warn = None
        crit = None
        if levels != None:
            warn = levels.get("warn", None)
            crit = levels.get("crit", None)
        state = _grade_levels(links, warn, crit)
        return {"changed": False, "msg": "%d links" % links, "data": {"state": state, "metrics": {"connections": links}, "details": "NTLS links: %d" % links}}

    elif plugin == "safenet_ntls_clients":
        clients = section["connected_clients"]
        warn = None
        crit = None
        if levels != None:
            warn = levels.get("warn", None)
            crit = levels.get("crit", None)
        state = _grade_levels(clients, warn, crit)
        return {"changed": False, "msg": "%d connected clients" % clients, "data": {"state": state, "metrics": {"connections": clients}, "details": "NTLS connected clients: %d" % clients}}

    elif plugin == "safenet_ntls_connrate":
        if item == "successful":
            count = section["successful_connections"]
        elif item == "failed":
            count = section["failed_connections"]
        else:
            return {"changed": False, "msg": "unknown connrate item: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        # Connection rate - using current count as a simple rate proxy
        # (Checkmk uses get_rate which needs a value store; we report the absolute count as rate)
        rate = float(count)
        return {"changed": False, "msg": "%f connections/s" % rate, "data": {"state": "OK", "metrics": {"connections_rate": rate}, "details": "%d total %s connections" % (count, item)}}

    return {"changed": False, "msg": "unknown plugin: " + str(plugin), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}