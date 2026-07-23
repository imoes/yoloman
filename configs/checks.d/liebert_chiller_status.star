# ===== Starlark check module: liebert_chiller_status =====

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Read-only SNMP probe: fetch the chiller status OID
    # Base OID: .1.3.6.1.4.1.476.1.42.4.3.20.1.1.20.2
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        "1.3.6.1.4.1.476.1.42.4.3.20.1.1.20.2"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query SNMP (device not reachable or credentials wrong)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    line = res.stdout.strip()
    # Parse output like: .1.3.6.1.4.1.476.1.42.4.3.20.1.1.20.2 = INTEGER: 5
    status_str = ""
    idx = line.rfind(": ")
    if idx != -1:
        status_str = line[idx+2:].strip()
    else:
        # Alternative format: "value" or raw number
        parts = line.split()
        status_str = parts[len(parts)-1] if len(parts) > 0 else ""

    # Extract integer from the string (guard instead of try/except)
    status = 0
    if status_str.isdigit():
        status = int(status_str)

    # Checkmk logic: OK if status in [5, 7], else CRIT
    if status == 5 or status == 7:
        summary = "Device is in a OK state"
        state = "OK"
    else:
        summary = "Device is in a non OK state"
        state = "CRIT"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
