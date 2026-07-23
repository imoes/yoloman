# ===== Module-level constants =====
# APC ATS detection OID base
DETECT_OID_BASE = ".1.3.6.1.2.1.1.2.0"
APC_SYMMETRA_OID = ".1.3.6.1.4.1.318.1.1.1.3.2.1.0"

# SNMP base OIDs for input phase voltage
SNMP_BASE = ".1.3.6.1.4.1.318.1.1.1.3.2"
SNMP_VOLTAGE_OID = "1"


def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        # Detect if this is an APC ATS device using sysObjectID
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), DETECT_OID_BASE],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse sysObjectID value from output: ".1.3.6.1.4.1.318.1.1.1.3.2.1.0 = STRING: "APC Symmetra..."
        oid_line = res.stdout.strip()
        # Look for APC Symmetra in the response
        if not (oid_line.find(".1.3.6.1.4.1.318.") >= 0 or oid_line.find("APC") >= 0):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Check if we have the input voltage OID
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), APC_SYMMETRA_OID],
                      mutates=False)
        
        if res.rc == 0:
            # We have data - discover single service
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [{"item": "Input", "params": {}, "metrics": ["voltage"]}]
                },
            }
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
    
    # CHECK MODE
    item = params.get("item", "")
    
    # Only "Input" is valid for this check
    if item != "Input":
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch voltage value
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), APC_SYMMETRA_OID],
                  mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: ".1.3.6.1.4.1.318.1.1.1.3.2.1.0 = INTEGER: 2310" (in decivolts)
    # or similar format
    lines = res.stdout.strip().splitlines()
    if not lines:
        return {
            "changed": False,
            "msg": "empty response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse value - expect something like " = INTEGER: 2310"
    value_str = ""
    for line in lines:
        if "=" in line:
            parts = line.split("=", 1)
            if len(parts) == 2:
                value_str = parts[1].strip()
                break
    
    # Extract numeric value
    voltage_raw = 0.0
    if value_str:
        # Handle various formats: "INTEGER: 2310", "Gauge32: 2310", "2310"
        for token in value_str.split():
            if token.isdigit() or (token.startswith("-") and token[1:].isdigit()):
                voltage_raw = float(int(token))
                break
    
    # Convert from decivolts to volts
    voltage = voltage_raw / 10.0
    
    # Apply thresholds (Checkmk defaults: no thresholds, so OK state)
    # Checkmk elphase defaults: no explicit warn/crit for voltage
    warn = params.get("voltage", {}).get("upper", {}).get("warning")
    crit = params.get("voltage", {}).get("upper", {}).get("critical")
    
    # Checkmk defaults for voltage thresholds
    # If not specified, we use typical ranges or assume OK
    state = "OK"
    details = ""
    
    # Typical Checkmk thresholds for voltage (if needed)
    if warn != None and crit != None:
        if voltage >= crit:
            state = "CRIT"
            details = "voltage critical"
        elif voltage >= warn:
            state = "WARN"
            details = "voltage warning"
    else:
        # Without thresholds, checkmk typically returns OK for normal ranges
        # We assume 230V ± tolerance; checkmk doesn't provide explicit default thresholds for this plugin
        pass
    
    msg = "Voltage: %f V" % voltage
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": voltage},
            "details": details
        },
    }
