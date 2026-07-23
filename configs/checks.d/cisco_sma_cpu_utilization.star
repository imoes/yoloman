# Module-level constants
CPU_UTIL_OID = ".1.3.6.1.4.1.15497.1.1.1.2"

def main(ctx, params):
    # Discovery mode: yield one service with empty item and default params
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"util": (70.0, 80.0)},
                        "metrics": ["util"]
                    }
                ]
            }
        }

    # Check mode: fetch CPU utilization via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        CPU_UTIL_OID
    ], mutates=False)

    # Parse OID response: "<oid> = INTEGER: <value>"
    stdout = res.stdout.strip()
    if not stdout:
        return {
            "changed": False,
            "msg": "no SNMP data received",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Extract value: split once on '=' then on ':' or ' '
    parts = stdout.split("=")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "malformed SNMP response: " + stdout,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    value_part = parts[1].strip()
    # Handle common SNMP value formats: INTEGER: <num>, Gauge32: <num>, etc.
    for prefix in ["INTEGER: ", "Gauge32: ", "Counter32: ", " "]:
        if value_part.startswith(prefix):
            value_part = value_part[len(prefix):].strip()
            break

    # Check if numeric
    util_str = value_part.split()[0]  # Take first token in case of trailing text
    if not util_str.replace(".", "", 1).isdigit():
        return {
            "changed": False,
            "msg": "non-numeric CPU value: " + util_str,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    util = float(util_str)

    # Extract thresholds from params with defaults
    util_params = params.get("util", (70.0, 80.0))
    warn = util_params[0] if len(util_params) > 0 else 70.0
    crit = util_params[1] if len(util_params) > 1 else 80.0

    # Determine state
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Build message
    msg = "CPU utilization: %f%%" % util

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"util": util},
            "details": ""
        }
    }
