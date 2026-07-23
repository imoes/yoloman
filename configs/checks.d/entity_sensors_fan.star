# module-level constants
FAN_OID_BASE = ".1.3.6.1.2.1.99.1.1.1"
FAN_OID_END = ".1.3.6.1.2.1.99.1.1.1.4"
FAN_OID_STATUS = ".1.3.6.1.2.1.99.1.1.1.5"
ENTITY_OID_BASE = ".1.3.6.1.2.1.47.1.1.1.1"
ENTITY_OID_NAME = ".1.3.6.1.2.1.47.1.1.1.1.7"

SNMP_DEFAULT_COMMUNITY = "public"
SNMP_DEFAULT_HOST = "localhost"
SNMP_DEFAULT_VERSION = "2c"

FAN_DEFAULT_LOWER_WARN = 2000
FAN_DEFAULT_LOWER_CRIT = 1000

def _parse_snmp_output(res):
    # Parse snmpwalk output: "<OID> = <TYPE>: <value>"
    result = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Split on first space to separate OID from value part
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid = oid_part.strip()
        value_part = value_part.strip()
        # Extract value after type colon (e.g., "INTEGER: 1000" -> "1000")
        if ":" in value_part:
            value_str = value_part.split(":", 1)[1].strip()
        else:
            value_str = value_part
        # Remove trailing quotes if present
        if value_str.startswith('"') and value_str.endswith('"'):
            value_str = value_str[1:-1]
        result[oid] = value_str
    return result

def main(ctx, params):
    # Determine mode
    discover = params.get("_discover")
    
    # Get SNMP parameters from params
    community = params.get("community", SNMP_DEFAULT_COMMUNITY)
    host = params.get("host", SNMP_DEFAULT_HOST)
    
    # Discover mode: enumerate all fans with their metric names
    if discover:
        # Fetch entity physical names (fan descriptions)
        entity_res = ctx.run([
            "snmpwalk",
            "-v", SNMP_DEFAULT_VERSION,
            "-c", community,
            "-On", host,
            ENTITY_OID_NAME
        ], mutates=False)
        
        # Fetch fan speed values
        fan_res = ctx.run([
            "snmpwalk",
            "-v", SNMP_DEFAULT_VERSION,
            "-c", community,
            "-On", host,
            FAN_OID_END + ".4"  # entPhySensorValue
        ], mutates=False)
        
        # Fetch fan operational status
        status_res = ctx.run([
            "snmpwalk",
            "-v", SNMP_DEFAULT_VERSION,
            "-c", community,
            "-On", host,
            FAN_OID_STATUS + ".5"  # entPhySensorOperStatus
        ], mutates=False)
        
        # Parse SNMP outputs
        entity_names = _parse_snmp_output(entity_res)
        fan_speeds = _parse_snmp_output(fan_res)
        fan_statuses = _parse_snmp_output(status_res)
        
        # Build discovered items
        items = []
        # Look for entries ending with numeric identifiers in fan OID range
        for oid in fan_speeds.keys():
            # Extract index from OID end (e.g., ...1.4.2 -> index "2")
            parts = oid.rsplit(".", 1)
            if len(parts) != 2:
                continue
            index_str = parts[1]
            index = int(index_str) if index_str.isdigit() else None
            if index == None:
                continue
            
            # Get corresponding name from ENTITY section
            entity_oid = ENTITY_OID_NAME + "." + str(index)
            name = entity_names.get(entity_oid, "")
            
            # Skip non-fan entries (must be an operational fan sensor)
            # Filter: name contains "Fan" or similar
            if not name:
                continue
            
            # Add to discovered list
            items.append({
                "item": name,
                "params": {
                    "lower": [FAN_DEFAULT_LOWER_WARN, FAN_DEFAULT_LOWER_CRIT],
                    "output_metrics": False
                },
                "metrics": ["fan"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: validate specific item (fan)
    item = params.get("item", "")
    lower_warn = FAN_DEFAULT_LOWER_WARN
    lower_crit = FAN_DEFAULT_LOWER_CRIT
    lower_tuple = params.get("lower")
    if lower_tuple != None and type(lower_tuple) == "list" and len(lower_tuple) >= 2:
        lower_warn = lower_tuple[0]
        lower_crit = lower_tuple[1]
    
    output_metrics = params.get("output_metrics", False)
    
    # Fetch data for this item
    # First, get entity name to find corresponding index
    entity_res = ctx.run([
        "snmpwalk",
        "-v", SNMP_DEFAULT_VERSION,
        "-c", community,
        "-On", host,
        ENTITY_OID_NAME
    ], mutates=False)
    
    # Get index from entity name
    index = None
    for line in entity_res.stdout.splitlines():
        line = line.strip()
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid = oid_part.strip()
        value_part = value_part.strip()
        if ":" in value_part:
            value_str = value_part.split(":", 1)[1].strip()
        else:
            value_str = value_part
        if value_str.startswith('"') and value_str.endswith('"'):
            value_str = value_str[1:-1]
        if value_str == item:
            # Extract index from OID (e.g., ...1.7.5 -> "5")
            oid_parts = oid.rsplit(".", 1)
            if len(oid_parts) == 2:
                index_str = oid_parts[1]
                index = int(index_str) if index_str.isdigit() else None
            break
    
    if index == None:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch fan speed and status for this index
    speed_oid = FAN_OID_END + ".4." + str(index)
    status_oid = FAN_OID_STATUS + ".5." + str(index)
    
    speed_res = ctx.run([
        "snmpget",
        "-v", SNMP_DEFAULT_VERSION,
        "-c", community,
        "-On", host,
        speed_oid
    ], mutates=False)
    
    status_res = ctx.run([
        "snmpget",
        "-v", SNMP_DEFAULT_VERSION,
        "-c", community,
        "-On", host,
        status_oid
    ], mutates=False)
    
    # Parse results
    speed_val = None
    for line in speed_res.stdout.splitlines():
        line = line.strip()
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        if oid_part.strip() == speed_oid:
            value_part = value_part.strip()
            if ":" in value_part:
                value_str = value_part.split(":", 1)[1].strip()
            else:
                value_str = value_part
            if value_str.isdigit():
                speed_val = int(value_str)
            break
    
    status_val = None
    status_descr = "Unknown"
    for line in status_res.stdout.splitlines():
        line = line.strip()
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        if oid_part.strip() == status_oid:
            value_part = value_part.strip()
            if ":" in value_part:
                value_str = value_part.split(":", 1)[1].strip()
            else:
                value_str = value_part
            if value_str.isdigit():
                status_val = int(value_str)
                # Map operational status: 1=ok, 2=warn, 3=crit, 4=unknown, 5=notPresent, 6=notFunctioning
                if status_val == 1:
                    status_descr = "OK"
                elif status_val == 2:
                    status_descr = "Warning"
                elif status_val == 3:
                    status_descr = "Critical"
                elif status_val == 4:
                    status_descr = "Unknown"
                elif status_val == 5:
                    status_descr = "Not Present"
                elif status_val == 6:
                    status_descr = "Not Functioning"
                else:
                    status_descr = "Unknown"
            break
    
    # Determine state and build message
    # Operational status takes precedence
    # Map status_val to Checkmk states: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
    if status_val == None:
        return {
            "changed": False,
            "msg": "fan data unavailable: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Map operational status to state
    state = "OK"
    if status_val in [2, 3]:  # warn/crit status
        state = "WARN" if status_val == 2 else "CRIT"
    elif status_val == 4:
        state = "UNKNOWN"
    elif status_val in [5, 6]:
        state = "CRIT"
    
    # Speed levels check (lower thresholds)
    if speed_val != None:
        if speed_val <= lower_crit:
            state = "CRIT"
        elif speed_val <= lower_warn:
            state = "WARN"
    
    # Build message
    msg = "Operational status: " + status_descr
    if speed_val != None:
        msg = msg + ", Speed: %d RPM" % speed_val
    
    # Build metrics
    metrics = {}
    if speed_val != None and output_metrics:
        metrics["fan"] = speed_val
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
