# Top-level constants (required for Starlark)
OID_BYPASS = ".1.3.6.1.4.1.25597.13.1.41.0"
BYPASS_OID_END = "41"
BASE_OID = ".1.3.6.1.4.1.25597.13.1"
DEFAULT_VALUE = 0

def _discover_item(ctx, community, host):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, BASE_OID, "41"
    ], mutates=False)
    # Parse snmpwalk output: "<OID> = INTEGER: <value>" or similar
    out = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(OID_BYPASS):
            # Extract value after last colon/space
            parts = stripped.split(":")
            if len(parts) >= 2:
                value_str = parts[-1].strip()
                if value_str.isdigit():
                    out.append(value_str)
    return out

def _check_current_value(ctx, community, host, expected_value):
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, OID_BYPASS
    ], mutates=False)
    
    if not res.stdout.strip():
        return {
            "state": "UNKNOWN",
            "msg": "no data from SNMP",
            "metrics": {},
            "details": ""
        }
    
    # Parse snmpget output: "<OID> = INTEGER: <value>"
    line = res.stdout.strip()
    if not line.startswith(OID_BYPASS):
        return {
            "state": "UNKNOWN",
            "msg": "unexpected SNMP output",
            "metrics": {},
            "details": ""
        }
    
    parts = line.split(":")
    if len(parts) < 2:
        return {
            "state": "UNKNOWN",
            "msg": "malformed SNMP output",
            "metrics": {},
            "details": ""
        }
    
    value_str = parts[-1].strip()
    if not value_str.isdigit():
        return {
            "state": "UNKNOWN",
            "msg": "non-numeric bypass value: " + value_str,
            "metrics": {},
            "details": ""
        }
    
    current_value = int(value_str)
    state = "OK"
    msg = "Bypass E-Mail count: " + str(current_value)
    
    if current_value != expected_value:
        state = "CRIT"
        msg = msg + " (was %d before)" % expected_value
    
    return {
        "state": state,
        "msg": msg,
        "metrics": {"bypass_count": current_value},
        "details": ""
    }

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode
    if params.get("_discover"):
        bypass_values = _discover_item(ctx, community, host)
        if len(bypass_values) >= 1:
            return {
                "changed": False,
                "msg": "discovered 1 bypass item",
                "data": {
                    "discovery": [
                        {
                            "item": "",  # Single-service check
                            "params": {"value": int(bypass_values[0])},
                            "metrics": ["bypass_count"]
                        }
                    ]
                }
            }
        else:
            return {
                "changed": False,
                "msg": "no bypass data found",
                "data": {"discovery": []}
            }
    
    # Check mode
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "unexpected item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    expected_value = params.get("value", DEFAULT_VALUE)
    result = _check_current_value(ctx, community, host, expected_value)
    
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"]
        }
    }
