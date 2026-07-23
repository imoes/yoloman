# ===== Starlark check module: knuerr_rms_temp =====
# Reads ambient temperature from SNMP OID .1.3.6.1.4.1.3711.15.1.1.1.1.4 (1/10 °C)
# Single-service check (item: "Ambient")

# Module-level defaults (Checkmk defaults)
DEFAULT_WARN = 30.0
DEFAULT_CRIT = 35.0
SNMP_BASE_OID = ".1.3.6.1.4.1.3711.15.1.1.1.1"
TEMP_OID = "4"

def _discover_knuerr_rms_temp(ctx, params):
    # Single-service check: always discover one item "Ambient"
    return [{"item": "Ambient",
             "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
             "metrics": ["temperature"]}]

def _check_knuerr_rms_temp(ctx, params):
    item = params.get("item", "Ambient")
    
    # Read SNMP data for temperature OID
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        SNMP_BASE_OID + "." + TEMP_OID
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False,
                "msg": "SNMP query failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    output = res.stdout.strip()
    if not output:
        return {"changed": False,
                "msg": "no SNMP data received",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output: look for "OID = INTEGER: value" or similar format
    # Expected format: ".1.3.6.1.4.1.3711.15.1.1.1.1.4 = INTEGER: 250"
    # Extract the integer value (temperature * 10)
    temp_raw = None
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        # Split on '=' and get the value part
        idx = line.find("=")
        if idx != -1:
            value_part = line[idx + 1:].strip()
            # Try to extract integer value (INTEGER:, Gauge32:, etc.)
            if value_part.startswith("INTEGER:"):
                value_str = value_part[8:].strip()
                temp_raw = int(value_str) if value_str.isdigit() else None
            elif value_part.startswith("Gauge32:"):
                value_str = value_part[8:].strip()
                temp_raw = int(value_str) if value_str.isdigit() else None
    
    if temp_raw == None:
        return {"changed": False,
                "msg": "temperature value not found in SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Convert to °C (raw value is 1/10 °C)
    temp_c = float(temp_raw) / 10.0
    
    # Extract thresholds from params
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    
    # Determine state based on thresholds
    if temp_c >= crit:
        state = "CRIT"
    elif temp_c >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg = "Temperature: %f C" % temp_c
    
    return {"changed": False,
            "msg": msg,
            "data": {"state": state,
                     "metrics": {"temperature": temp_c},
                     "details": ""}}

def main(ctx, params):
    if params.get("_discover"):
        discovery = _discover_knuerr_rms_temp(ctx, params)
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    
    return _check_knuerr_rms_temp(ctx, params)