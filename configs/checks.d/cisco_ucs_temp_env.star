# Module-level constants
SENSOR_NAMES = ["Ambient", "Front", "IO-Hub", "Rear"]
SNMP_BASE_OID = ".1.3.6.1.4.1.9.9.719.1.9.44.1"
SNMP_OIDS = ["4", "8", "13", "21"]
DEFAULT_WARN = 30.0
DEFAULT_CRIT = 35.0

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            SNMP_BASE_OID + "." + SNMP_OIDS[0] + " " +
            SNMP_BASE_OID + "." + SNMP_OIDS[1] + " " +
            SNMP_BASE_OID + "." + SNMP_OIDS[2] + " " +
            SNMP_BASE_OID + "." + SNMP_OIDS[3]
        ], mutates=False)
        
        # Parse snmpwalk output - each OID yields lines like: OID = INTEGER: value
        temps = {}
        lines = res.stdout.splitlines() if res.stdout else []
        for line in lines:
            if line.find(" = ") == -1:
                continue
            oid_part, value_part = line.split(" = ", 1)
            if value_part.find(": ") != -1:
                value = value_part.split(": ", 1)[1].strip()
            else:
                value = value_part.strip()
            
            # Map OID suffix to sensor name
            if oid_part.endswith(".4"):
                temps["Ambient"] = value
            elif oid_part.endswith(".8"):
                temps["Front"] = value
            elif oid_part.endswith(".13"):
                temps["IO-Hub"] = value
            elif oid_part.endswith(".21"):
                temps["Rear"] = value
        
        discovery = []
        for name in SENSOR_NAMES:
            if name in temps:
                discovery.append({
                    "item": name,
                    "params": {"levels": (DEFAULT_WARN, DEFAULT_CRIT)},
                    "metrics": ["temperature"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    warn = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))[0]
    crit = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))[1]
    
    # Fetch all sensor values via SNMP
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        SNMP_BASE_OID + "." + SNMP_OIDS[0] + " " +
        SNMP_BASE_OID + "." + SNMP_OIDS[1] + " " +
        SNMP_BASE_OID + "." + SNMP_OIDS[2] + " " +
        SNMP_BASE_OID + "." + SNMP_OIDS[3]
    ], mutates=False)
    
    temps = {}
    lines = res.stdout.splitlines() if res.stdout else []
    for line in lines:
        if line.find(" = ") == -1:
            continue
        oid_part, value_part = line.split(" = ", 1)
        if value_part.find(": ") != -1:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part.strip()
        
        # Map OID suffix to sensor name
        if oid_part.endswith(".4"):
            temps["Ambient"] = value
        elif oid_part.endswith(".8"):
            temps["Front"] = value
        elif oid_part.endswith(".13"):
            temps["IO-Hub"] = value
        elif oid_part.endswith(".21"):
            temps["Rear"] = value
    
    # Check requested item
    if item not in temps:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Validate temperature value before parsing
    temp_str = temps[item]
    temp_val = int(temp_str) if temp_str.isdigit() else 0
    
    # Determine state based on thresholds
    state = "OK"
    if temp_val >= crit:
        state = "CRIT"
    elif temp_val >= warn:
        state = "WARN"
    
    # Format message as Checkmk style
    msg = "%s: %d C" % (item, temp_val)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp_val},
            "details": ""
        }
    }
