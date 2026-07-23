# Checkmk check plugin: cmk/plugins/pfsense/agent_based/pfsense_status.py
# Translate to read-only Starlark check module

def main(ctx, params):
    # Discovery mode: always yield one service if section exists (i.e., SNMP available)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: read JSON from the pfsense special agent output
    path = "/var/lib/check-mk-agent/source/pfsense_status.json"
    if not ctx.file_exists(path):
        return {
            "changed": False,
            "msg": "pfSense status data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read(path)
    if not content:
        return {
            "changed": False,
            "msg": "pfSense status data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = json.decode(content)

    # Get status from JSON (pfsense special agent uses string values)
    status = data.get("status", "")

    # Map status to state
    if status == "running":
        state = "OK"
        summary = "Running"
    elif status == "notRunning":
        state = "CRIT"
        summary = "Not running"
    else:
        state = "UNKNOWN"
        summary = "Unknown status value: " + repr(status)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
