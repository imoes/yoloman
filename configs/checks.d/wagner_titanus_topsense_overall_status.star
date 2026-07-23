def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
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
    
    # Check mode - get overall status
    # The SNMP data structure from the check plugin:
    # Tree base=".1.3.6.1.4.1.34187.21501.1.1" has oids=["1","2","3","1000","1001","1002","1003","1004","1005","1006"]
    # But we need the psw_failure which is at index 9, so OID ".1.3.6.1.4.1.34187.21501.1.1.10"
    # Actually, looking more carefully, the section fetch has 10 OIDs: positions 0-9
    # Position 9 corresponds to OID ".1.3.6.1.4.1.34187.21501.1.1.10"
    
    # We'll use snmpget to query the specific OID
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.34187.21501.1.1.10"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse the output: "SNMPv2-SMI::enterprises.34187.21501.1.1.10 = INTEGER: 0"
    line = res.stdout.strip()
    if not line:
        return {
            "changed": False,
            "msg": "No SNMP data received",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract the value after the last space or "="
    parts = line.split()
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "Could not parse SNMP output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Get the value - typically the last part
    value_str = parts[-1].strip()
    
    # Check if it's an integer value
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "Could not parse status value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    psw_failure = int(value_str)
    
    if psw_failure == 0:
        return {
            "changed": False,
            "msg": "Overall Status reports OK",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    else:
        return {
            "changed": False,
            "msg": "Overall Status reports a problem",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }
