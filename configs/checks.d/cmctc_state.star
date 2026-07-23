def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Single-service check: item is always ""
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.2606.4.2.1.0", ".1.3.6.1.4.1.2606.4.2.2.0"
    ], mutates=False)

    status_code = None
    units = None

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Parse "oid value" format
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        value = value.strip()
        if oid.endswith(".1.3.6.1.4.1.2606.4.2.1.0"):
            status_code = value
        elif oid.endswith(".1.3.6.1.4.1.2606.4.2.2.0"):
            units = value

    # Fallback if SNMP failed to return data
    if status_code == None or units == None:
        return {
            "changed": False,
            "msg": "SNMP data missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Map status code per original logic: "1" -> failed, "2" -> ok
    status_map = {"1": "failed", "2": "ok"}
    status = status_map.get(status_code, "unknown[" + status_code + "]")

    # State logic: ok -> OK, anything else -> CRIT
    state = "OK" if status == "ok" else "CRIT"

    return {
        "changed": False,
        "msg": "Status: " + status + ", Units connected: " + str(units),
        "data": {"state": state, "metrics": {}, "details": ""},
    }
