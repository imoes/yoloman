# Top-level constants
DETECT_OID = ".1.3.6.1.2.1.1.1.0"
DETECT_PATTERN = "Aruba.+2930M.*"

DEFAULT_LEVELS_ABS_UPPER = (500.0, 600.0)
DEFAULT_LEVELS_ABS_LOWER = (0.0, 0.0)
DEFAULT_LEVELS_PERC_UPPER = (80.0, 90.0)
DEFAULT_LEVELS_PERC_LOWER = (0.0, 0.0)

PSU_STATE_MAP = {
    "1": "OK",  # NotPresent
    "2": "OK",  # NotPlugged
    "3": "OK",  # Powered
    "4": "CRIT",  # Failed
    "5": "CRIT",  # PermFailure
    "6": "OK",  # Max
    "7": "CRIT",  # AuxFailure
    "8": "CRIT",  # NotPowered
    "9": "CRIT",  # AuxNotPowered
}


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Detect if this is a 2930M device
        snmp_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", 
             params.get("host", "localhost"), DETECT_OID],
            mutates=False,
        )
        if snmp_res.rc != 0 or DETECT_PATTERN not in snmp_res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Check for presence of PSU data
        snmp_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", 
             params.get("host", "localhost"), ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"],
            mutates=False,
        )
        if snmp_res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse PSU entries
        discovered = []
        for line in snmp_res.stdout.splitlines():
            if "=" in line:
                oid_part = line.split("=")[0].strip()
                # Get PSU index from OID end
                parts = oid_part.split(".")
                if len(parts) > 0:
                    index = parts[-1]
                    # Gather basic PSU info for discovery
                    discovered.append({
                        "item": "PSU " + index,
                        "params": {
                            "levels_abs_upper": DEFAULT_LEVELS_ABS_UPPER,
                            "levels_abs_lower": DEFAULT_LEVELS_ABS_LOWER,
                            "levels_perc_upper": DEFAULT_LEVELS_PERC_UPPER,
                            "levels_perc_lower": DEFAULT_LEVELS_PERC_LOWER,
                        },
                        "metrics": ["power", "power_utilization"],
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode
    item = params.get("item", "")
    
    # Extract PSU index from item name (e.g. "PSU 1" -> "1")
    if item.startswith("PSU "):
        index = item[4:].strip()
    else:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Gather PSU data
    base_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1." + index
    
    # Get all PSU data for this index via snmpget
    state_oid = base_oid + ".2"
    failures_oid = base_oid + ".3"
    temp_oid = base_oid + ".4"
    voltage_info_oid = base_oid + ".5"
    wattage_curr_oid = base_oid + ".6"
    wattage_max_oid = base_oid + ".7"
    last_call_oid = base_oid + ".8"
    model_oid = base_oid + ".9"
    
    snmp_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-On", 
         params.get("host", "localhost"), state_oid, failures_oid, temp_oid,
         voltage_info_oid, wattage_curr_oid, wattage_max_oid, last_call_oid, model_oid],
        mutates=False,
    )
    
    if snmp_res.rc != 0:
        return {"changed": False, "msg": "PSU data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse output lines
    data = {}
    for line in snmp_res.stdout.splitlines():
        if "=" in line:
            parts = line.strip().split("=", 1)
            if len(parts) == 2:
                oid = parts[0].strip()
                val = parts[1].strip()
                if oid.endswith(".2"):
                    data["state"] = val
                elif oid.endswith(".3"):
                    data["failures"] = val
                elif oid.endswith(".4"):
                    data["temperature"] = val
                elif oid.endswith(".5"):
                    data["voltage_info"] = val
                elif oid.endswith(".6"):
                    data["wattage_curr"] = val
                elif oid.endswith(".7"):
                    data["wattage_max"] = val
                elif oid.endswith(".8"):
                    data["last_call"] = val
                elif oid.endswith(".9"):
                    data["model"] = val
    
    # Check required fields before parsing
    if "wattage_curr" not in data or "wattage_max" not in data:
        return {"changed": False, "msg": "PSU wattage data missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Safely parse numeric values with guards
    wattage_curr_str = data["wattage_curr"]
    wattage_max_str = data["wattage_max"]
    state_val = data["state"].split()[-1] if data["state"] else "1"
    voltage_info = data.get("voltage_info", "").strip('"')
    
    # Check if strings are numeric before converting
    wattage_curr = int(wattage_curr_str) if wattage_curr_str.isdigit() else 0
    wattage_max = int(wattage_max_str) if wattage_max_str.isdigit() else 0
    
    # Determine PSU state
    state_map_val = PSU_STATE_MAP.get(state_val, "CRIT")
    
    # Check levels
    levels_abs_upper = params.get("levels_abs_upper", DEFAULT_LEVELS_ABS_UPPER)
    levels_abs_lower = params.get("levels_abs_lower", DEFAULT_LEVELS_ABS_LOWER)
    levels_perc_upper = params.get("levels_perc_upper", DEFAULT_LEVELS_PERC_UPPER)
    levels_perc_lower = params.get("levels_perc_lower", DEFAULT_LEVELS_PERC_LOWER)
    
    # Determine worst state (OK > WARN > CRIT > UNKNOWN)
    state = "OK"
    
    # Check absolute levels
    if levels_abs_upper != None and type(levels_abs_upper) == "list" and len(levels_abs_upper) >= 2:
        if wattage_curr >= levels_abs_upper[1]:
            state = "CRIT"
        elif wattage_curr >= levels_abs_upper[0]:
            state = "WARN" if state != "CRIT" else state
    
    if levels_abs_lower != None and type(levels_abs_lower) == "list" and len(levels_abs_lower) >= 2:
        if wattage_curr <= levels_abs_lower[1]:
            state = "CRIT"
        elif wattage_curr <= levels_abs_lower[0]:
            state = "WARN" if state != "CRIT" else state
    
    # Check percentage levels (notice_only, so lower priority than state)
    if wattage_max > 0:
        utilization = (wattage_curr / float(wattage_max)) * 100.0
        
        if levels_perc_upper != None and type(levels_perc_upper) == "list" and len(levels_perc_upper) >= 2:
            if utilization >= levels_perc_upper[1]:
                state = "CRIT"
            elif utilization >= levels_perc_upper[0]:
                state = "WARN" if state != "CRIT" else state
        
        if levels_perc_lower != None and type(levels_perc_lower) == "list" and len(levels_perc_lower) >= 2:
            if utilization <= levels_perc_lower[1]:
                state = "CRIT"
            elif utilization <= levels_perc_lower[0]:
                state = "WARN" if state != "CRIT" else state
    
    # Adjust state if PSU itself reports CRIT
    if state_map_val == "CRIT" and state == "OK":
        state = state_map_val
    
    # Build metrics
    metrics = {"power": float(wattage_curr)}
    if wattage_max > 0:
        metrics["power_utilization"] = float((wattage_curr / float(wattage_max)) * 100.0)
    
    # Build message
    msg_parts = ["Wattage: %fW" % wattage_curr]
    if wattage_max > 0:
        msg_parts.append("(%f%%)" % ((wattage_curr / float(wattage_max)) * 100.0))
    
    details = ""
    if "voltage_info" in data:
        details = "Voltage Info: " + voltage_info
    
    # Return result
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }
