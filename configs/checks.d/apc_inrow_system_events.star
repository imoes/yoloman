# Module: apc_inrow_system_events.star
# Checkmk check: apc_inrow_system_events
# Read-only Starlark translation - gathers SNMP data and reports system events

DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_BASE = ".1.3.6.1.4.1.318"

SNMP_BASE = ".1.3.6.1.4.1.318.1.1.13.3.1.2.1"
SNMP_OID_DESCRIPTION = "3"  # airIRAlarmDescription

def main(ctx, params):
    # Discovery mode: yield single service item
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), DETECT_OID
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed",
                "data": {"discovery": []}
            }
        
        # Detect if this is an APC device (ATS/InRow) by checking sysObjectID
        lines = res.stdout.splitlines()
        if len(lines) == 0:
            return {
                "changed": False,
                "msg": "no sysObjectID returned",
                "data": {"discovery": []}
            }
        
        # Parse first line: "OID = STRING: value"
        first_line = lines[0].strip()
        if first_line.find("=") == -1:
            return {
                "changed": False,
                "msg": "invalid sysObjectID format",
                "data": {"discovery": []}
            }
            
        oid_value = first_line.split("=", 1)[1].strip()
        
        # Check if sysObjectID starts with .1.3.6.1.4.1.318 (APC)
        if not oid_value.startswith(DETECT_BASE):
            return {
                "changed": False,
                "msg": "not an APC device",
                "data": {"discovery": []}
            }
        
        # Now fetch the events section
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), SNMP_BASE + "." + SNMP_OID_DESCRIPTION
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk for events failed",
                "data": {"discovery": []}
            }
        
        # Count events (non-empty descriptions)
        events = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.find("=") == -1:
                continue
            value_part = line.split("=", 1)[1].strip()
            # Skip empty strings
            if value_part:
                events.append(value_part)
        
        # Single-service check: always yield one service with item ""
        return {
            "changed": False,
            "msg": "discovered system events section",
            "data": {"discovery": [
                {"item": "", "params": {"state": 2}, "metrics": []}
            ]},
        }
    
    # Check mode for the single service
    item = params.get("item", "")
    
    # Fetch the events
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), SNMP_BASE + "." + SNMP_OID_DESCRIPTION
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk for events failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse events
    events = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.find("=") == -1:
            continue
        value_part = line.split("=", 1)[1].strip()
        # Skip empty strings
        if value_part:
            events.append(value_part)
    
    state = params.get("state", 2)
    
    # Determine state and message
    if events:
        # Report first event as summary; others could be in details if needed
        summary = events[0]
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": "CRIT" if state == 2 else ("WARN" if state == 1 else "OK"),
                "metrics": {},
                "details": "; ".join(events[1:]) if len(events) > 1 else ""
            }
        }
    else:
        return {
            "changed": False,
            "msg": "No service events",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
