# Translated from Checkmk check: checkmk.apc_netbotz_sensors_humidity
# Monitors APC Netbotz humidity sensor values via SNMP and grades against
# humidity thresholds (warn/crit). Read-only: never mutates.

HUMIDITY_BASE = ".1.3.6.1.4.1.5528.100.4.1.2.1"
TEMP_BASE = ".1.3.6.1.4.1.5528.100.4.1.1.1"
DEWPOINT_BASE = ".1.3.6.1.4.1.5528.100.4.1.3.1"
SYS_OID_BASE = ".1.3.6.1.4.1.5528.100"
NB50_SYS_OID = ".1.3.6.1.4.1.52674.500"


def _snmp_get_oid(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _is_appc_netbotz(ctx, host, community):
    sysoid = _snmp_get_oid(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if not sysoid:
        return False
    if sysoid.startswith(SYS_OID_BASE + ".20.10"):
        return True
    if sysoid.startswith(NB50_SYS_OID):
        return True
    return False


def _walk_humidity(ctx, host, community):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, HUMIDITY_BASE + ".7"], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val_str = ""
        if len(parts) > 1:
            val_str = parts[1].strip()
        idx = oid[len(HUMIDITY_BASE + ".7") + 1:]
        if not idx:
            continue
        rows.append((idx, val_str))
    return rows


def _get_label(ctx, host, community, idx):
    oid = HUMIDITY_BASE + ".1." + idx
    return _snmp_get_oid(ctx, host, community, oid)


def _get_plugged(ctx, host, community, idx):
    oid = HUMIDITY_BASE + ".2." + idx
    val = _snmp_get_oid(ctx, host, community, oid)
    if val == "":
        return False
    return int(val) != 0


def _get_humidity_value(ctx, host, community, idx):
    oid = HUMIDITY_BASE + ".7." + idx
    val_str = _snmp_get_oid(ctx, host, community, oid)
    if val_str == "":
        return None
    return float(val_str)


def _grade_humidity(value, warn, crit, warn_low, crit_low):
    if value == None:
        return "UNKNOWN"
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    if crit_low != None and value <= crit_low:
        return "CRIT"
    if warn_low != None and value <= warn_low:
        return "WARN"
    return "OK"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_appc_netbotz(ctx, host, community):
        if params.get("_discover"):
            return {"changed": False, "msg": "no APC Netbotz detected", "data": {"discovery": []}}
        return {"changed": False, "msg": "no APC Netbotz detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "APC Netbotz not found"}}

    if params.get("_discover"):
        rows = _walk_humidity(ctx, host, community)
        discovered = []
        for idx, val_str in rows:
            if not _get_plugged(ctx, host, community, idx):
                continue
            if val_str == "":
                continue
            label = _get_label(ctx, host, community, idx)
            discovered.append({
                "item": label if label else idx,
                "params": {"warn": 60, "crit": 65, "warn_low": 35, "crit_low": 30},
                "metrics": ["humidity"],
            })
        return {"changed": False,
                "msg": "discovered %d humidity sensors" % len(discovered),
                "data": {"discovery": discovered}}

    item = params.get("item", "")
    warn = params.get("warn", 60)
    crit = params.get("crit", 65)
    warn_low = params.get("warn_low", 35)
    crit_low = params.get("crit_low", 30)

    rows = _walk_humidity(ctx, host, community)
    found_value = None
    found_label = None
    for idx, val_str in rows:
        if not _get_plugged(ctx, host, community, idx):
            continue
        label = _get_label(ctx, host, community, idx)
        display = label if label else idx
        if display == item or idx == item:
            if val_str != "":
                found_value = float(val_str)
                found_label = label
                break

    if found_value == None:
        return {"changed": False, "msg": "no humidity sensor reading for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = _grade_humidity(found_value, warn, crit, warn_low, crit_low)
    details = "[%s]" % found_label if found_label else ""
    return {"changed": False,
            "msg": "%s %f%%" % (details, found_value) if found_label else "%f%%" % found_value,
            "data": {"state": state, "metrics": {"humidity": found_value}, "details": details}}