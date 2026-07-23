# Safenet HSM Event Stats Check Module
# Translated from Checkmk plugin cmk.plugins.safenet.agent_based.safenet_hsm

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: always yield one service for this check
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                "critical_events",
                "noncritical_events",
                "critical_event_rate",
                "noncritical_event_rate",
                "operation_errors",
                "error_rate",
                "operation_requests",
                "request_rate"
            ]}]}
        }

    # Check mode: gather data from SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # OID base from the original: .1.3.6.1.4.1.12383.3.1.1
    base_oid = ".1.3.6.1.4.1.12383.3.1.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".2", base_oid + ".3", base_oid + ".4"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + (res.stderr.strip() if res.stderr.strip() else "unknown error"),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output: look for lines matching our OIDs
    values = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        val_str = parts[1].strip()
        # Extract value after colon/space
        if ":" in val_str:
            val_str = val_str.split(":", 1)[1].strip()
        # Remove trailing type indicators like INTEGER:, Gauge32:, etc.
        val_str = val_str.split()[-1] if val_str else "0"
        # Remove type prefixes like "Gauge32:" or "INTEGER:"
        for prefix in ["Gauge32:", "INTEGER:", "Counter32:", "Counter64:"]:
            if val_str.startswith(prefix):
                val_str = val_str[len(prefix):].strip()
        # Final numeric extraction
        val_str = val_str.lstrip('"').rstrip('"')
        # Check if string is numeric before converting
        oid_num = oid.rsplit(".", 1)[-1]
        values[oid_num] = int(val_str) if val_str.isdigit() else 0

    # Map OIDs to fields (from original SNMPTree base=".1.3.6.1.4.1.12383.3.1.1" oids=["1", "2", "3", "4"])
    # .1 -> operation_requests
    # .2 -> operation_errors
    # .3 -> critical_events
    # .4 -> noncritical_events
    operation_requests = values.get("1", 0)
    operation_errors = values.get("2", 0)
    critical_events = values.get("3", 0)
    noncritical_events = values.get("4", 0)

    # Build section dict
    section = {
        "operation_requests": operation_requests,
        "operation_errors": operation_errors,
        "critical_events": critical_events,
        "noncritical_events": noncritical_events,
    }

    # Default params from Checkmk: all set to ("no_levels", None)
    critical_events_levels = params.get("critical_events", ("no_levels", None))
    noncritical_events_levels = params.get("noncritical_events", ("no_levels", None))
    critical_event_rate_levels = params.get("critical_event_rate", ("no_levels", None))
    noncritical_event_rate_levels = params.get("noncritical_event_rate", ("no_levels", None))

    # Determine state based on values and levels
    state = "OK"
    messages = []
    metrics = {}

    # Check critical_events
    if critical_events_levels[0] != "no_levels":
        upper = critical_events_levels[1]
        if critical_events >= upper:
            state = "CRIT"
            messages.append("%d critical events >= %f" % (critical_events, upper))
        elif critical_events >= params.get("critical_events", ("no_levels", 0))[1]:
            if state != "CRIT":
                state = "WARN"
            messages.append("%d critical events >= %f" % (critical_events, params.get("critical_events", ("no_levels", 0))[1]))
    metrics["critical_events"] = critical_events

    # Check noncritical_events
    if noncritical_events_levels[0] != "no_levels":
        upper = noncritical_events_levels[1]
        if noncritical_events >= upper:
            state = "CRIT"
            messages.append("%d noncritical events >= %f" % (noncritical_events, upper))
        elif noncritical_events >= params.get("noncritical_events", ("no_levels", 0))[1]:
            if state != "CRIT":
                state = "WARN"
            messages.append("%d noncritical events >= %f" % (noncritical_events, params.get("noncritical_events", ("no_levels", 0))[1]))
    metrics["noncritical_events"] = noncritical_events

    # Report rates as 0 (rate calculations require persistent value_store which is unavailable in Starlark)
    metrics["critical_event_rate"] = 0.0
    metrics["noncritical_event_rate"] = 0.0
    metrics["operation_errors"] = operation_errors
    metrics["operation_requests"] = operation_requests
    metrics["error_rate"] = 0.0
    metrics["request_rate"] = 0.0

    # If any level was exceeded, append rate info
    if state != "OK":
        messages.append("rates unavailable (first run)")

    # Build details string
    details = ", ".join(messages) if messages else "All metrics within thresholds"

    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }