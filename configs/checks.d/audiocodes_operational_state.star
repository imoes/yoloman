# ===== Starlark check module for audiocodes_operational_state =====
# Reads acSysModuleOperationalState, acSysModulePresence, acSysModuleHAStatus
# via SNMP and reports operational state per module.

# OID tree for operational state (base from Checkmk source)
_OID_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.21.1"
_OID_OPERATIONAL_STATE = ".1.3.6.1.4.1.5003.9.10.10.4.21.1.8"
_OID_PRESENCE = ".1.3.6.1.4.1.5003.9.10.10.4.21.1.4"
_OID_HA_STATUS = ".1.3.6.1.4.1.5003.9.10.10.4.21.1.9"

# Operational state values per audiocodes docs: 0=unknown,1=ok,2=warning,3=critical
_STATE_MAP = {
    "0": "unknown",
    "1": "ok",
    "2": "warning",
    "3": "critical",
}

def _parse_snmp_line(line):
    # Parse a single SNMP output line: 'OID = STRING: value' or 'OID = INTEGER: value'
    line = line.strip()
    if not line or line.find("=") == -1:
        return None, None
    idx = line.find("=")
    oid_part = line[:idx].strip()
    value_part = line[idx+1:].strip()
    # Extract last OID segment (the end) for item key
    segments = oid_part.split(".")
    if len(segments) == 0:
        return None, None
    item = segments[-1]
    if item.isdigit():
        item = str(int(item))  # normalize leading zeros
    # Extract value after type indicator
    if value_part.find(":") != -1:
        idx2 = value_part.find(":")
        value = value_part[idx2+1:].strip()
    else:
        value = value_part
    return item, value

def _snmp_walk(ctx, base_oid, community, host):
    # Walk an SNMP OID and return dict of item -> value for each leaf
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid
    ], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    out = {}
    for line in res.stdout.splitlines():
        item, value = _parse_snmp_line(line)
        if item != None and value != None:
            out[item] = value
    return out

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Gather data from all three OIDs
        operational = _snmp_walk(ctx, _OID_OPERATIONAL_STATE, community, host)
        presence = _snmp_walk(ctx, _OID_PRESENCE, community, host)
        ha_status = _snmp_walk(ctx, _OID_HA_STATUS, community, host)

        # Combine into modules: use OID end (item) as key
        # Only include modules that have an operational state entry
        modules = []
        for item in operational.keys():
            op_val = operational.get(item, "")
            pres_val = presence.get(item, "")
            ha_val = ha_status.get(item, "")

            # Map operational state to Checkmk state
            state_val = _STATE_MAP.get(op_val, "unknown")
            if state_val == "ok":
                state = "OK"
            elif state_val == "warning":
                state = "WARN"
            elif state_val == "critical":
                state = "CRIT"
            else:
                state = "UNKNOWN"

            # Only discover if module appears present and has valid state
            if state != "UNKNOWN":
                modules.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d modules" % len(modules),
            "data": {"discovery": modules}
        }

    # Check mode: fetch single item data
    item = params.get("item", "")
    if item == "":
        item = "1"  # fallback for legacy single-service devices

    operational = _snmp_walk(ctx, _OID_OPERATIONAL_STATE, community, host)
    if operational.get(item) == None:
        return {
            "changed": False,
            "msg": "module %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    op_val = operational.get(item, "0")
    state_val = _STATE_MAP.get(op_val, "unknown")
    if state_val == "ok":
        state = "OK"
        msg = "module %s: ok" % item
    elif state_val == "warning":
        state = "WARN"
        msg = "module %s: warning" % item
    elif state_val == "critical":
        state = "CRIT"
        msg = "module %s: critical" % item
    else:
        state = "UNKNOWN"
        msg = "module %s: unknown state (raw value %s)" % (item, op_val)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
