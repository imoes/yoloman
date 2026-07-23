# Constants
DETECT_OID = ".1.3.6.1.2.1.1.1.0"
BVIP_POWEROID = ".1.3.6.1.4.1.3967.1.1.10"
DEFAULT_LEVELS = [50, 60]

# Helper to parse SNMP output lines: "<OID> = <TYPE>: <value>"
def _parse_snmp_line(line):
    if not line.strip():
        return None, None
    parts = line.strip().split(" = ", 1)
    if len(parts) != 2:
        return None, None
    oid_part, value_part = parts
    # Extract OID and value
    oid = oid_part.strip()
    # Extract type and value: "INTEGER: 123", "STRING: value", etc.
    if ": " in value_part:
        typ, val = value_part.split(": ", 1)
        return oid, val.strip()
    return oid, value_part.strip()

# Discover function
def _discover(ctx):
    # Detect BVIP device by reading sysDescr
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.params.get("community", "public"), 
                   "-On", ctx.params.get("host", "localhost"), DETECT_OID], mutates=False)
    sysdesc = ""
    for line in res.stdout.splitlines():
        oid, val = _parse_snmp_line(line)
        if oid == DETECT_OID and val != None:
            sysdesc = val.lower()
            break
    
    # Check for BVIP device keywords
    is_bvip = False
    for kw in ["flexidome", "vip-x", "dinion", "autodome"]:
        if kw in sysdesc:
            is_bvip = True
            break
    
    if not is_bvip:
        return {"changed": False, "msg": "not a BVIP device", "data": {"discovery": []}}
    
    # Read POE power OID
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.params.get("community", "public"), 
                   "-On", ctx.params.get("host", "localhost"), BVIP_POWEROID], mutates=False)
    power_val = None
    for line in res.stdout.splitlines():
        oid, val = _parse_snmp_line(line)
        if oid != None and oid.startswith(BVIP_POWEROID) and val != None:
            # Try to parse as integer
            if val.isdigit():
                power_val = int(val)
            else:
                # Extract number from "INTEGER: 123" style
                v = val.split(":")
                if len(v) > 1 and v[-1].strip().isdigit():
                    power_val = int(v[-1].strip())
            break
    
    # If no power data, don't discover
    if power_val == None:
        return {"changed": False, "msg": "no POE power data found", "data": {"discovery": []}}
    
    # Discover single-service check (no per-item breakdown)
    return {"changed": False, "msg": "discovered POE power",
            "data": {"discovery": [{"item": "", "params": {"levels": DEFAULT_LEVELS},
                                    "metrics": ["power"]}]}}
    
# Check function for one item (always "" for this check)
def _check(ctx, params):
    host = ctx.params.get("host", "localhost")
    community = ctx.params.get("community", "public")
    levels = params.get("levels", DEFAULT_LEVELS)
    warn = float(levels[0])
    crit = float(levels[1])
    
    # Read POE power OID
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, BVIP_POWEROID], mutates=False)
    power_val = None
    
    for line in res.stdout.splitlines():
        oid, val = _parse_snmp_line(line)
        if oid == BVIP_POWEROID and val != None:
            # Extract number from "INTEGER: 123" style
            v = val.split(":")
            if len(v) > 1 and v[-1].strip().isdigit():
                power_val = int(v[-1].strip())
            elif val.isdigit():
                power_val = int(val)
            break
    
    if power_val == None:
        return {"changed": False, "msg": "POE power data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    watt = float(power_val) / 10.0
    
    # Determine state based on levels (upper bounds)
    state = "OK"
    if watt >= crit:
        state = "CRIT"
    elif watt >= warn:
        state = "WARN"
    
    return {"changed": False,
            "msg": "Power: %f W" % watt,
            "data": {"state": state,
                     "metrics": {"power": watt},
                     "details": ""}}

def main(ctx, params):
    if params.get("_discover") != None:
        return _discover(ctx)
    return _check(ctx, params)