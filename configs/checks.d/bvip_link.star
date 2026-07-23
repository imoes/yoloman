# Top-level constants (no try/except, no imports, no classes)
STATES = {
    0: "No Link",
    1: "10 MBit - HalfDuplex",
    2: "10 MBit - FullDuplex",
    3: "100 Mbit - HalfDuplex",
    4: "100 Mbit - FullDuplex",
    5: "1 Gbit - FullDuplex",
    7: "Wifi",
}

# Default params (from Checkmk source)
DEFAULT_OK_STATES = [0, 4, 5]
DEFAULT_WARN_STATES = [7]
DEFAULT_CRIT_STATES = [1, 2, 3]

# Base OID for SNMP walk
BASE_OID = ".1.3.6.1.4.1.3967.1.5.1.8"

def _extract_int_from_value(value_str):
    # Extract integer from value_str like "INTEGER: 4" or "4"
    parts = value_str.split(":")
    for tok in parts[-1].strip().split():
        if tok.isdigit():
            return int(tok)
    return None

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: fetch one OID to detect presence of data
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), BASE_OID], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Count lines of output (each line is a link instance)
        lines = [l for l in res.stdout.splitlines() if l.strip()]
        discovered = []
        for i in range(len(lines)):
            # Suggest same params for every item; item is empty for single-service check
            discovered.append({"item": "", "params": {
                "ok_states": DEFAULT_OK_STATES,
                "warn_states": DEFAULT_WARN_STATES,
                "crit_states": DEFAULT_CRIT_STATES,
            }, "metrics": []})
        return {"changed": False, "msg": "discovered %d link(s)" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode: single-service (item always "")
    ok_states = params.get("ok_states", DEFAULT_OK_STATES)
    warn_states = params.get("warn_states", DEFAULT_WARN_STATES)
    crit_states = params.get("crit_states", DEFAULT_CRIT_STATES)

    # Fetch raw link status OID
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), BASE_OID], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no link status data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
    if not lines:
        return {"changed": False, "msg": "no link status data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse link statuses
    # In Checkmk: enumerate starting at 1 (count starts at 1)
    status_lines = []
    for count, line in enumerate(lines, start=1):
        # Parse "OID = STRING: value" -> extract last part
        parts = line.split(" = ")
        if len(parts) < 2:
            status_lines.append({"count": count, "status": None, "raw": None})
            continue
        value_str = parts[-1].strip()
        val = _extract_int_from_value(value_str)
        status_lines.append({"count": count, "status": val, "raw": value_str})

    # Determine overall state: per-line logic like Checkmk source
    # If multiple links, use most severe state (CRIT > WARN > OK)
    best_state = "OK"
    summary_parts = []
    for item in status_lines:
        count = item["count"]
        link_status = item["status"]
        if link_status == None:
            state = "UNKNOWN"
            summary = "%d: State: Not Implemented (None)" % count
        elif link_status in ok_states:
            state = "OK"
            summary = "%d: State: %s" % (count, STATES.get(link_status, "Not Implemented (%d)" % link_status))
        elif link_status in crit_states:
            state = "CRIT"
            summary = "%d: State: %s" % (count, STATES.get(link_status, "Not Implemented (%d)" % link_status))
        elif link_status in warn_states:
            state = "WARN"
            summary = "%d: State: %s" % (count, STATES.get(link_status, "Not Implemented (%d)" % link_status))
        else:
            state = "UNKNOWN"
            summary = "%d: State: Not Implemented (%d)" % (count, link_status)

        summary_parts.append(summary)
        # Update best_state: CRIT > WARN > UNKNOWN > OK
        if state == "CRIT":
            best_state = "CRIT"
        elif state == "WARN" and best_state not in ["CRIT"]:
            best_state = "WARN"
        elif state == "UNKNOWN" and best_state not in ["CRIT", "WARN"]:
            best_state = "UNKNOWN"

    msg = "; ".join(summary_parts)
    return {"changed": False, "msg": msg,
            "data": {"state": best_state, "metrics": {}, "details": ""}}
