# Module-level constants (metric names, default thresholds, etc.)
OID_HOST_FAULT = ".1.3.6.1.4.1.9694.1.5.2.1.0"
OID_PRAVAIL_HOST_FAULT = ".1.3.6.1.4.1.9694.1.6.2.1.0"
SNMP_COMMUNITY_DEFAULT = "public"
SNMP_HOST_DEFAULT = "localhost"

def main(ctx, params):
    # Discovery mode: always yields exactly one service with item ""
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": []
                    }
                ]
            }
        }

    # Check mode for the single item (item is "" per discovery)
    # Determine which OID to query based on host facts (os_family/distribution not directly available,
    # so use a heuristic: try the peakflow OID first; if no data, try pravail)
    host = params.get("host", SNMP_HOST_DEFAULT)
    community = params.get("community", SNMP_COMMUNITY_DEFAULT)

    # Try peakflow first (more common for this plugin)
    res_peakflow = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        OID_HOST_FAULT
    ], mutates=False)

    if res_peakflow.rc == 0 and res_peakflow.stdout.strip():
        # Parse output: "<OID> = STRING: <value>"
        line = res_peakflow.stdout.strip()
        if ": " in line:
            value = line.split(": ", 1)[1].strip().strip('"')
        else:
            value = line.split(" = ", 1)[-1].strip().strip('"')
    else:
        # Fall back to pravail OID
        res_pravail = ctx.run([
            "snmpget",
            "-v2c",
            "-c", community,
            "-On", host,
            OID_PRAVAIL_HOST_FAULT
        ], mutates=False)

        if res_pravail.rc != 0 or not res_pravail.stdout.strip():
            # No data available
            return {
                "changed": False,
                "msg": "unable to retrieve host fault status",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": ""
                }
            }

        # Parse pravail output
        line = res_pravail.stdout.strip()
        if ": " in line:
            value = line.split(": ", 1)[1].strip().strip('"')
        else:
            value = line.split(" = ", 1)[-1].strip().strip('"')

    # Check value against OK threshold
    if value == "No Fault":
        state = "OK"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": value,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
