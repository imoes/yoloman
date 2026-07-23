# Module-level constants
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_APC_PREFIX = ".1.3.6.1.4.1.318"

AIRFLOW_OID_BASE = ".1.3.6.1.4.1.318.1.1.13.3.2.2.2"
AIRFLOW_FLOW_OID = AIRFLOW_OID_BASE + ".5"

# Default thresholds from Checkmk check
DEFAULT_LEVEL_LOW = (500.0, 200.0)
DEFAULT_LEVEL_HIGH = (1000.0, 1100.0)


def main(ctx, params):
    # Discovery mode: check if APC device is present
    if params.get("_discover"):
        # Detect APC devices by checking sysObjectID prefix
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), DETECT_OID], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Extract value from snmpget output: ".1.3.6.1.2.1.1.2.0 = STRING: ..."
        sys_object_id = res.stdout.strip()
        # Extract the OID string after the last '=' or '='
        eq_idx = sys_object_id.find("=")
        if eq_idx == -1:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        oid_val = sys_object_id[eq_idx + 1:].strip()
        # Remove leading quotes if present
        if oid_val.startswith('"'):
            oid_val = oid_val.strip('"')
        # Check if it starts with APC OIDs
        is_apc = oid_val.startswith(DETECT_APC_PREFIX)
        
        # For single-service check (no per-item breakdown), return one item with empty string
        if is_apc:
            return {"changed": False, "msg": "discovered 1 items",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": ["airflow"]}]}}
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
    
    # Check mode: get airflow value
    # Get SNMP value for airflow
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), AIRFLOW_FLOW_OID], mutates=False)
    
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "no airflow data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output: "OID = STRING: value" or similar formats
    # Extract numeric value from output
    line = res.stdout.strip()
    eq_idx = line.find("=")
    if eq_idx == -1:
        return {"changed": False, "msg": "invalid airflow data format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_part = line[eq_idx + 1:].strip()
    # Remove type prefix if present (e.g., "STRING:", "INTEGER:")
    for prefix in ["STRING:", "INTEGER:", "Gauge32:", "Counter32:"]:
        if value_part.startswith(prefix):
            value_part = value_part[len(prefix):].strip()
            break
    
    # Extract numeric value (remove trailing quotes if present)
    value_str = value_part.strip('"').strip("'").strip()
    
    # Guard before float conversion - simple validation instead of try/except
    flow = 0.0
    # Check for empty string
    if value_str == "":
        return {"changed": False, "msg": "invalid airflow data: empty value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Validate characters in string
    valid_chars = "0123456789.-"
    for c in value_str:
        if c not in valid_chars:
            return {"changed": False, "msg": "invalid airflow data: invalid characters",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Check for multiple decimal points
    if value_str.count(".") > 1:
        return {"changed": False, "msg": "invalid airflow data: multiple decimal points",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Check for invalid minus sign positions (should only be at start)
    minus_count = value_str.count("-")
    if minus_count > 1 or (minus_count == 1 and value_str[0] != "-"):
        return {"changed": False, "msg": "invalid airflow data: invalid minus sign",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Convert string to float
    flow = 0.0
    if value_str.replace(".", "").replace("-", "").isdigit() or value_str.replace("-", "").replace(".", "").isdigit():
        # Use simple parsing approach
        flow_val = 0.0
        neg = False
        if value_str.startswith("-"):
            neg = True
            value_str = value_str[1:]
        
        parts = value_str.split(".")
        int_part = parts[0] if parts else "0"
        dec_part = parts[1] if len(parts) > 1 else ""
        
        # Convert integer part
        int_val = 0
        for c in int_part:
            int_val = int_val * 10 + (ord(c) - ord("0"))
        
        # Convert decimal part
        dec_val = 0.0
        if dec_part != "":
            dec_mult = 1.0
            for c in dec_part:
                dec_mult = dec_mult * 10.0
                dec_val = dec_val + float(ord(c) - ord("0")) / dec_mult
        
        flow_val = float(int_val) + dec_val
        if neg:
            flow_val = -flow_val
        
        flow = flow_val
    else:
        return {"changed": False, "msg": "invalid airflow data: not a number",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get thresholds from params or use defaults
    warn_low, crit_low = params.get("level_low", DEFAULT_LEVEL_LOW)
    warn_high, crit_high = params.get("level_high", DEFAULT_LEVEL_HIGH)
    
    # Determine state based on thresholds
    state = "OK"
    message = ""
    
    # Check low thresholds
    if flow < crit_low:
        state = "CRIT"
        message = " too low"
    elif flow < warn_low:
        state = "WARN"
        message = " too low"
    
    # Check high thresholds (override low if both conditions apply)
    if flow >= crit_high:
        state = "CRIT"
        message = " too high"
    elif flow >= warn_high:
        state = "WARN"
        message = " too high"
    
    # Prepare summary message
    summary = "Current: %f l/s%s" % (flow, message)
    
    return {"changed": False, "msg": summary,
            "data": {
                "state": state,
                "metrics": {"airflow": flow},
                "details": "",
            }}
