# Checkmk checkpoint_connections check translated to Starlark
# Reads: .1.3.6.1.4.1.2620.1.1.25.3 (fwNumConn - current connections)
# Parameters: levels (warn, crit) with default (40000, 50000)

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": [40000, 50000]},
                        "metrics": ["connections"]
                    }
                ]
            }
        }

    # CHECK MODE
    item = params.get("item", "")
    # Only one service expected; any non-empty item is invalid
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # SNMP walk the connection count OID: .1.3.6.1.4.1.2620.1.1.25.3
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        "1.3.6.1.4.1.2620.1.1.25.3"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: "1.3.6.1.4.1.2620.1.1.25.3 = INTEGER: 19190"
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "empty SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    line = lines[0].strip()
    # Extract value after the last colon
    idx = line.rfind(":")
    if idx == -1:
        return {
            "changed": False,
            "msg": "unable to parse value from: " + line,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = line[idx+1:].strip()
    # Remove trailing space and non-digit characters
    value_str = value_str.split()[0] if value_str else ""
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid value format: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    current = int(value_str)

    # Get thresholds from params, with Checkmk defaults
    levels = params.get("levels", [40000, 50000])
    warn = levels[0] if len(levels) > 0 else 40000
    crit = levels[1] if len(levels) > 1 else 50000

    # Determine state based on upper levels
    if current >= crit:
        state = "CRIT"
    elif current >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Build message in Checkmk style
    msg = "Current connections: %d" % current

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"connections": current},
            "details": ""
        }
    }
