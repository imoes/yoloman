# Module-level constants
THREADS_OID = ".1.3.6.1.4.1.13315.100.200.1.1.2.1"
DEFAULT_WARN = 2000
DEFAULT_CRIT = 4000

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"levels": ["levels", [DEFAULT_WARN, DEFAULT_CRIT]]}, "metrics": ["threads"]}]}
        }

    # SNMP walk the thread count OID
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, THREADS_OID], mutates=False)
    
    if not res.stdout or res.stdout.find("No Such Object") != -1 or res.stdout.find("Timeout") != -1:
        return {
            "changed": False,
            "msg": "could not retrieve thread count",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse first line: "OID = INTEGER: <value>"
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "empty SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    line = lines[0].strip()
    # Extract value after last colon (e.g., "OID = INTEGER: 123" -> "123")
    colon_idx = line.rfind(":")
    if colon_idx == -1:
        return {
            "changed": False,
            "msg": "unexpected SNMP response format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = line[colon_idx + 1:].strip()
    # Guard against non-digit values instead of try/except
    if not value_str or not value_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid thread count value: %s" % value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    nthreads = int(value_str)

    # Extract thresholds from params
    warn, crit = None, None
    levels_tuple = params.get("levels", ["levels", [DEFAULT_WARN, DEFAULT_CRIT]])
    if levels_tuple != "no_levels" and type(levels_tuple) == "list" and len(levels_tuple) >= 2:
        warn = levels_tuple[1]
        crit = levels_tuple[2] if len(levels_tuple) > 2 else levels_tuple[1]

    # Determine state based on thresholds
    state = "OK"
    summary = "%d threads" % nthreads
    if crit != None and nthreads >= crit:
        state = "CRIT"
        summary = "%d threads (critical at %d)" % (nthreads, crit)
    elif warn != None and nthreads >= warn:
        state = "WARN"
        summary = "%d threads (warning at %d)" % (nthreads, warn)

    metrics = {"threads": nthreads}
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
