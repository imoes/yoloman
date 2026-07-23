def main(ctx, params):
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

    # Normal check mode (single-service check with empty item)
    # Cisco UCS memory total is retrieved via SNMP from:
    # .1.3.6.1.4.1.9.9.719.1.9.35.1.9 cucsComputeRackUnitAvailableMemory
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        "1.3.6.1.4.1.9.9.719.1.9.35.1.9"
    ], mutates=False)

    # Check if SNMP command succeeded
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

    # Parse SNMP output: should contain the memory value in MB
    # Expected format: SNMPv2-SMI::enterprises.9.9.719.1.9.35.1.9 = INTEGER: 123456 MB
    out = res.stdout.strip()
    
    # Extract the value after the last space or '=' sign
    # Common format: OID = INTEGER: VALUE
    if "=" in out:
        value_part = out.split("=", 1)[1].strip()
    else:
        return {
            "changed": False,
            "msg": "Unexpected SNMP output format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract the integer value (might be followed by " MB" or other text)
    parts = value_part.split()
    if len(parts) == 0:
        return {
            "changed": False,
            "msg": "No value in SNMP output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Try to extract numeric value
    raw_value = ""
    for part in parts:
        if part.isdigit():
            raw_value = part
            break
    
    if raw_value == "":
        # Alternative: try to find integer at beginning of value part
        idx = value_part.find(":")
        if idx >= 0:
            value_str = value_part[idx+1:].strip()
            # Remove non-digit suffixes like " MB"
            for i, ch in enumerate(value_str):
                if not ch.isdigit():
                    value_str = value_str[:i]
                    break
            raw_value = value_str
    
    if raw_value == "" or not raw_value.isdigit():
        return {
            "changed": False,
            "msg": "Could not parse memory value from SNMP output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    total_memory = int(raw_value)
    
    # Return OK state with total memory summary
    return {
        "changed": False,
        "msg": "Total Memory: %d MB" % total_memory,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }
