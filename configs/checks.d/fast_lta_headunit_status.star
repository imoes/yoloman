# Fast LTA Headunit Status / Replication check plugin
# Translated from Checkmk SNMP check to read-only Starlark check module.
# Monitors Fast LTA headunit status and replication via SNMP.

def _snmp_walk(ctx, community, host, oid):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid
    ], mutates=False)
    rows = {}
    if res.rc != 0 or res.stdout == "":
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        o = line[:sp]
        v = line[sp + 1:]
        rows[o] = v
    return rows


def _snmp_get(ctx, community, host, oid):
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, oid
    ], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return None
    val = res.stdout.strip()
    # Strip possible quotes
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    return val


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # SNMP OIDs (from the Checkmk SNMPSection / SNMPTree definitions)
    sysoid_oid = ".1.3.6.1.2.1.1.2.0"
    fast_oid_base = ".1.3.6.1.4.1.27417.2"
    status_oid = ".1.3.6.1.4.1.27417.2.1"
    app_ro_oid = ".1.3.6.1.4.1.27417.2.5"

    # Detect: sysObjectID must start with the Fast LTA enterprise prefix,
    # and at least one of the Fast LTA OIDs must exist.
    sysoid = _snmp_get(ctx, community, host, sysoid_oid)
    if sysoid == None or not sysoid.startswith(".1.3.6.1.4.1.8072.3.2.10"):
        return {"changed": False, "msg": "Fast LTA device not detected (sysObjectID mismatch)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    exists_status = _snmp_get(ctx, community, host, status_oid)
    exists_appro = _snmp_get(ctx, community, host, app_ro_oid)
    if exists_status == None and exists_appro == None:
        return {"changed": False, "msg": "Fast LTA device not detected (no Fast LTA OIDs present)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Discovery: yield one Service per item. Fast LTA headunit is a
        # single-service check (no per-item breakdown), so item is "".
        discovery = []
        # Both sub-checks apply whenever the device is detected.
        discovery.append({"item": "", "params": {}, "metrics": []})
        discovery.append({"item": "replication", "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    if item == "" or item == "status":
        head_unit_status = _snmp_get(ctx, community, host, status_oid)
        app_read_only_status = _snmp_get(ctx, community, host, app_ro_oid)
        if head_unit_status == None:
            return {"changed": False,
                    "msg": "Head Unit status OID not available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        head_unit_status_map = {
            "-1": "workerDefect",
            "-2": "workerNotStarted",
            "2": "workerBooting",
            "3": "workerRfRRunning",
            "10": "appBooting",
            "20": "appNoCubes",
            "30": "appVirginCubes",
            "40": "appRfrPossible",
            "45": "appRfrMixedCubes",
            "50": "appRfrActive",
            "60": "appReady",
            "65": "appMixedCubes",
            "70": "appReadOnly",
            "75": "appEnterpriseCubes",
            "80": "appEnterpriseMixedCubes",
        }

        state = "CRIT"
        if head_unit_status == "60":
            state = "OK"
        elif head_unit_status == "70" and app_read_only_status == "0":
            state = "OK"

        if head_unit_status in head_unit_status_map:
            message = "Head Unit status is %s." % head_unit_status_map[head_unit_status]
        else:
            message = "Head Unit status is %s." % head_unit_status

        return {"changed": False, "msg": message,
                "data": {"state": state, "metrics": {}, "details": ""}}

    if item == "replication":
        node_replication_mode = _snmp_get(ctx, community, host, ".1.3.6.1.4.1.27417.2.2")
        replication_status = _snmp_get(ctx, community, host, ".1.3.6.1.4.1.27417.2.5")
        if replication_status == None:
            return {"changed": False,
                    "msg": "Replication status OID not available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        head_unit_replication_map = {
            "0": "Slave",
            "1": "Master",
            "255": "standalone",
        }

        if replication_status == "1":
            message = "Replication is running."
            state = "OK"
        else:
            message = "Replication is not running (!!)."
            state = "CRIT"

        if node_replication_mode != None and node_replication_mode in head_unit_replication_map:
            message += " This node is %s." % head_unit_replication_map[node_replication_mode]
        else:
            mode_str = node_replication_mode if node_replication_mode != None else "?"
            message += " Replication mode of this node is %s." % mode_str

        return {"changed": False, "msg": message,
                "data": {"state": state, "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "unknown item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}