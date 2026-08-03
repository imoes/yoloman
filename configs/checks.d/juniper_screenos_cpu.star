# Juniper ScreenOS CPU utilization check — SNMP translation
# Reads 1-min and 15-min CPU utilization from Juniper ScreenOS devices via SNMP

SCREENOS_UTIL1_OID = ".1.3.6.1.4.1.3224.16.1.2"
SCREENOS_UTIL15_OID = ".1.3.6.1.4.1.3224.16.1.4"
SYS_OBJECT_ID_OID = ".1.3.6.1.2.1.1.2.0"
SCREENOS_ENTERPRISE_PREFIX = ".1.3.6.1.4.1.3224.1"

def _is_screenos(ctx, host, community):
    """Detect Juniper ScreenOS by sysObjectID enterprise prefix."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OBJECT_ID_OID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    return res.stdout.strip().startswith(SCREENOS_ENTERPRISE_PREFIX)

def _get_levels(params):
    """Return (warn, crit) warn/crit tuple from params.util or defaults."""
    levels = params.get("util")
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        return (float(levels[0]), float(levels[1]))
    if levels != None and type(levels) == "tuple" and len(levels) >= 2:
        return (float(levels[0]), float(levels[1]))
    return (80.0, 90.0)

def _grade(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return None
    return res.stdout.strip()

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_screenos(ctx, host, community):
            return {"changed": False, "msg": "not a Juniper ScreenOS device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"util": [80.0, 90.0]},
                     "metrics": ["util1", "util15"]},
                ]}}

    item = params.get("item", "")
    util1_raw = _snmp_get(ctx, host, community, SCREENOS_UTIL1_OID)
    util15_raw = _snmp_get(ctx, host, community, SCREENOS_UTIL15_OID)
    if util1_raw == None or util15_raw == None:
        return {"changed": False,
                "msg": "could not read CPU utilization from host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util1 = float(util1_raw)
    util15 = float(util15_raw)
    warn, crit = _get_levels(params)
    state15 = _grade(util15, warn, crit)

    metrics = {"util1": util1, "util15": util15}
    details = "1min: %s%%, 15min: %s%%" % (util1_raw, util15_raw)
    msg = "CPU utilization 1min: %s%%, 15min: %s%% (%s)" % (
        util1_raw, util15_raw, state15)

    return {"changed": False,
            "msg": msg,
            "data": {"state": state15,
                     "metrics": metrics,
                     "details": details}}