# synology_fans.py — translated from Checkmk synology_fans check
# Monitors Synology NAS fan status via SNMP.
# Source: cmk/plugins/synology/agent_based/synology_fans.py

# OID base for Synology fan status (1.3.6.1.4.1.6574.1.4)
# .1 = System fan, .2 = CPU fan
SYS_BASE = ".1.3.6.1.4.1.6574.1.4"
SYS_OID_SYSTEM = SYS_BASE + ".1"
SYS_OID_CPU = SYS_BASE + ".2"

# Fan status enum values (from synology FanStatus)
FAN_NORMAL = 1   # OK
FAN_FAILURE = 2  # CRIT

# Map each fan item to its numeric SNMP index suffix.
FAN_OIDS = {
    "System": SYS_OID_SYSTEM,
    "CPU": SYS_OID_CPU,
}


def _snmp_get(ctx, host, community, oid):
    """Fetch a scalar SNMP value, returning the bare numeric string or None."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    # rc == 127 -> snmpget not installed; rc != 0 -> device unreachable / no such OID
    if res.rc != 0 or res.skipped:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val


def _probe_fans(ctx, params):
    """Gather current fan statuses from the device. Returns dict or None."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    statuses = {}
    for item, oid in FAN_OIDS.items():
        raw = _snmp_get(ctx, host, community, oid)
        if raw == None:
            return None
        # Guard the int conversion (no try/except in Starlark).
        statuses[item] = int(raw) if raw.lstrip("-").isdigit() else None
    return statuses


def main(ctx, params):
    # Discovery mode: enumerate items this host actually has.
    if params.get("_discover"):
        statuses = _probe_fans(ctx, params)
        if not statuses:
            return {
                "changed": False,
                "msg": "no synology fan status available",
                "data": {"discovery": []},
            }
        discovery = []
        for item in statuses:
            discovery.append({
                "item": item,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d fan items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: evaluate one item.
    item = params.get("item", "")
    statuses = _probe_fans(ctx, params)
    if statuses == None:
        return {
            "changed": False,
            "msg": "no synology fan status available for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if item not in statuses:
        return {
            "changed": False,
            "msg": "no such fan item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    status = statuses[item]
    if status == FAN_NORMAL:
        state = "OK"
        summary = "Operating normally"
    elif status == FAN_FAILURE:
        state = "CRIT"
        summary = "Fan failed"
    else:
        state = "UNKNOWN"
        summary = "Unknown fan status code %s" % str(status)
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }