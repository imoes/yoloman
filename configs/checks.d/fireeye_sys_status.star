# ===== check plugin: fireeye_sys_status.star =====
# Starlark translation of Checkmk's fireeye_sys_status check
# Read-only check: gathers SNMP-like agent data and reports system status

def main(ctx, params):
    # Discovery mode: yield one service for this host (single-service check)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ]
            },
        }

    # Normal check mode: query system status via agent
    res = ctx.run(["snmp", "walk", "-O", "Qn", ".1.3.6.1.4.1.25597.11.1.1"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP error: " + res.stderr}
        }

    lines = res.stdout.splitlines()
    status = ""
    model = ""
    serial = ""

    for line in lines:
        if line.startswith(".1.3.6.1.4.1.25597.11.1.1.1="):
            status = line.split("=", 1)[1]
        elif line.startswith(".1.3.6.1.4.1.25597.11.1.1.2="):
            model = line.split("=", 1)[1]
        elif line.startswith(".1.3.6.1.4.1.25597.11.1.1.3="):
            serial = line.split("=", 1)[1]

    # Validate we got the required fields
    if status == "":
        return {
            "changed": False,
            "msg": "no system status available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Missing status field"}
        }

    # Determine state based on status string (case-insensitive)
    if status.lower() == "good" or status.lower() == "ok":
        state = "OK"
    else:
        state = "CRIT"

    # Build summary message
    msg = "Status: %s" % status.lower()
    # Add model and serial to details if available
    details = ""
    if model != "":
        details = "Model: %s" % model
    if serial != "":
        if details != "":
            details = details + ", "
        details = details + "Serial: %s" % serial

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }
