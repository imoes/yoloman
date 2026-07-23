# Helper functions for parsing values
def _parse_value(raw_value):
    if raw_value.isdigit():
        return int(raw_value) / 10.0
    return None

def _parse_phase(raw_frequency, raw_voltage, raw_current, power, output_load):
    freq = _parse_value(raw_frequency)
    volt = _parse_value(raw_voltage)
    curr = _parse_value(raw_current)
    power_val = int(power) if power.isdigit() else None
    load_val = int(output_load) if output_load.isdigit() else None
    
    # Build dict for ElPhase equivalent
    phase = {}
    if freq != None:
        phase["frequency"] = freq
    if volt != None:
        phase["voltage"] = volt
    if curr != None:
        phase["current"] = curr
    if power_val != None:
        phase["power"] = power_val
    if load_val != None:
        phase["output_load"] = load_val
    
    return phase if phase else None

# discovery metrics mapping (what the check produces per item)
DISCOVERY_METRICS = ["frequency", "voltage", "current", "power", "output_load"]

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch SNMPTree data for ups_modulys_outphase
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2254.2.4.5"
        ], mutates=False)
        
        # Parse the first line only (single-line section)
        lines = res.stdout.splitlines()
        if not lines:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Collect OID values: each OID has format ".1.3.6.1.4.1.2254.2.4.5.X = INTEGER: Y"
        # We only need the values for OIDs 1-15 in order
        values = []
        for line in lines:
            line = line.strip()
            if line.startswith(".1.3.6.1.4.1.2254.2.4.5."):
                parts = line.split("=")
                if len(parts) == 2:
                    val = parts[1].strip()
                    # Extract numeric value (INTEGER: 123) or string value
                    if val.startswith("INTEGER: "):
                        values.append(val[9:])
                    elif val.startswith("STRING: "):
                        values.append(val[8:].strip('"'))
                    else:
                        values.append(val)
        
        if len(values) < 15:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse the first line as per original parse_ups_modulys_outphase
        phase_1 = _parse_phase(values[1], values[3], values[4], values[5], values[6])
        parsed = {}
        if phase_1 != None:
            parsed["Phase 1"] = phase_1
        
        # Check if 3-phase (values[2] == "3")
        if values[2] == "3":
            phase_2 = _parse_phase(values[1], values[7], values[8], values[9], values[10])
            if phase_2 != None:
                parsed["Phase 2"] = phase_2
            
            phase_3 = _parse_phase(values[1], values[11], values[12], values[13], values[14])
            if phase_3 != None:
                parsed["Phase 3"] = phase_3
        
        # Build discovery result
        discovery = []
        for item in parsed:
            discovery.append({
                "item": item,
                "params": {},
                "metrics": DISCOVERY_METRICS.copy()
            })
        
        return {"changed": False, "msg": "discovered %d items" % len(parsed),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2254.2.4.5"
    ], mutates=False)
    
    # Parse SNMP output (same as in discovery)
    lines = res.stdout.splitlines()
    values = []
    for line in lines:
        line = line.strip()
        if line.startswith(".1.3.6.1.4.1.2254.2.4.5."):
            parts = line.split("=")
            if len(parts) == 2:
                val = parts[1].strip()
                if val.startswith("INTEGER: "):
                    values.append(val[9:])
                elif val.startswith("STRING: "):
                    values.append(val[8:].strip('"'))
                else:
                    values.append(val)
    
    if len(values) < 15:
        return {"changed": False, "msg": "no data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse data
    parsed = {}
    phase_1 = _parse_phase(values[1], values[3], values[4], values[5], values[6])
    if phase_1 != None:
        parsed["Phase 1"] = phase_1
    
    if values[2] == "3":
        phase_2 = _parse_phase(values[1], values[7], values[8], values[9], values[10])
        if phase_2 != None:
            parsed["Phase 2"] = phase_2
        
        phase_3 = _parse_phase(values[1], values[11], values[12], values[13], values[14])
        if phase_3 != None:
            parsed["Phase 3"] = phase_3
    
    if item not in parsed:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    phase_data = parsed[item]
    
    # Use check_elphase logic (simplified for Starlark)
    # We'll evaluate each metric and determine worst state (OK/WARN/CRIT)
    # Default thresholds (from Checkmk plugin's check_ruleset_name="ups_outphase")
    # The default parameters are empty (check_default_parameters={}), meaning no explicit thresholds
    # So we only report states if data is available; no explicit thresholds means always OK
    state = "OK"
    metrics = {}
    details_parts = []
    
    # Check frequency (typical thresholds in Checkmk: (49, 51) for warning/critical ranges)
    # But default params are empty, so no thresholds applied unless user configured them.
    # In that case, we report the raw value only.
    if "frequency" in phase_data:
        val = phase_data["frequency"]
        metrics["frequency"] = val
        details_parts.append("frequency %f Hz" % val)
    
    # Check voltage
    if "voltage" in phase_data:
        val = phase_data["voltage"]
        metrics["voltage"] = val
        details_parts.append("voltage %f V" % val)
    
    # Check current
    if "current" in phase_data:
        val = phase_data["current"]
        metrics["current"] = val
        details_parts.append("current %f A" % val)
    
    # Check power
    if "power" in phase_data:
        val = phase_data["power"]
        metrics["power"] = val
        details_parts.append("power %d W" % val)
    
    # Check output_load
    if "output_load" in phase_data:
        val = phase_data["output_load"]
        metrics["output_load"] = val
        details_parts.append("output_load %d %%" % val)
    
    msg = ", ".join(details_parts) if details_parts else item + " data missing"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}