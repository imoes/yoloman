def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "Disk",
                        "params": {"levels": (36.0, 40.0)},
                        "metrics": ["temp"]
                    }
                ]
            }
        }
    
    item = params.get("item", "")
    if item != "Disk":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get the device identifier for detection
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check detect condition: sysObjectID must be .1.3.6.1.4.1.8072.3.2.10
    sysobjectid = res.stdout.strip().split("=")[-1].strip()
    if sysobjectid != ".1.3.6.1.4.1.8072.3.2.10":
        return {
            "changed": False,
            "msg": "device not detected (wrong sysObjectID)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check detect condition: sysDescr must contain "version" and "serial"
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sysdesc = res.stdout.strip().split("=")[-1].strip()
    if "version" not in sysdesc.lower() or "serial" not in sysdesc.lower():
        return {
            "changed": False,
            "msg": "device not detected (missing version/serial in sysDescr)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Now get the temperature value
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   ".1.3.6.1.4.1.31560.3.1.1.1.48"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse the temperature value
    value_str = res.stdout.strip().split("=")[-1].strip()
    if not value_str.isdigit() and not (value_str.startswith("-") and value_str[1:].isdigit()):
        return {
            "changed": False,
            "msg": "failed to parse temperature value: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    reading = int(value_str)
    
    # Apply thresholds
    levels = params.get("levels", (36.0, 40.0))
    warn = levels[0] if levels else 36.0
    crit = levels[1] if levels else 40.0
    
    if reading >= crit:
        state = "CRIT"
        msg = "Disk %d C (>= %f C)" % (reading, crit)
    elif reading >= warn:
        state = "WARN"
        msg = "Disk %d C (>= %f C)" % (reading, warn)
    else:
        state = "OK"
        msg = "Disk %d C" % reading
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": reading},
            "details": ""
        }
    }
