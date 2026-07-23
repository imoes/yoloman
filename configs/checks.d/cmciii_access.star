# Module-level constants (defined at top level per Starlark rules)
DETECT_OID_DESC = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
DETECT_OID_SYSDESC = ".1.3.6.1.2.1.1.1.0"


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk the CMCiii access sensor section via SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Get sysDescr to confirm device is CMC III LCP
        res_sysdesc = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_SYSDESC
        ], mutates=False)
        sysdesc_lines = res_sysdesc.stdout.splitlines()
        if len(sysdesc_lines) == 0 or "Rittal LCP" not in sysdesc_lines[0]:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Walk access sensors:DescName (OID suffix .6)
        res_desc = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".6"
        ], mutates=False)
        
        # Walk access sensors:Status (OID suffix .7)
        res_status = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".7"
        ], mutates=False)
        
        # Walk access sensors:Delay (OID suffix .8)
        res_delay = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".8"
        ], mutates=False)
        
        # Walk access sensors:Sensitivity (OID suffix .9)
        res_sens = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".9"
        ], mutates=False)
        
        # Walk access sensors:Location (OID suffix .2)
        res_loc = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".2"
        ], mutates=False)
        
        # Walk access sensors:Index (OID suffix .3)
        res_idx = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".3"
        ], mutates=False)
        
        # Parse OID -> value maps
        oid_to_val_desc = _parse_snmp_output(res_desc.stdout)
        oid_to_val_status = _parse_snmp_output(res_status.stdout)
        oid_to_val_delay = _parse_snmp_output(res_delay.stdout)
        oid_to_val_sens = _parse_snmp_output(res_sens.stdout)
        oid_to_val_loc = _parse_snmp_output(res_loc.stdout)
        oid_to_val_idx = _parse_snmp_output(res_idx.stdout)
        
        # Build sensor entries by extracting numeric IDs from OIDs
        # OID format: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.x.y
        # where x is the instance number, y is the field index
        sensors = {}
        for oid, val in oid_to_val_desc.items():
            parts = oid.split(".")
            if len(parts) >= 14:
                item_id = parts[-2]  # instance number (x)
                sensors.setdefault(item_id, {})["DescName"] = val
        
        for oid, val in oid_to_val_status.items():
            parts = oid.split(".")
            if len(parts) >= 14:
                item_id = parts[-2]
                sensors.setdefault(item_id, {})["Status"] = val
        
        for oid, val in oid_to_val_delay.items():
            parts = oid.split(".")
            if len(parts) >= 14:
                item_id = parts[-2]
                sensors.setdefault(item_id, {})["Delay"] = val
        
        for oid, val in oid_to_val_sens.items():
            parts = oid.split(".")
            if len(parts) >= 14:
                item_id = parts[-2]
                sensors.setdefault(item_id, {})["Sensitivity"] = val
        
        for oid, val in oid_to_val_loc.items():
            parts = oid.split(".")
            if len(parts) >= 14:
                item_id = parts[-2]
                sensors.setdefault(item_id, {})["_location_"] = val
        
        for oid, val in oid_to_val_idx.items():
            parts = oid.split(".")
            if len(parts) >= 14:
                item_id = parts[-2]
                sensors.setdefault(item_id, {})["_index_"] = val
        
        use_sensor_desc = params.get("use_sensor_description", False)
        discovery_list = []
        for item_id, entry in sensors.items():
            if "DescName" in entry:
                item = get_item(item_id, {"use_sensor_description": use_sensor_desc}, entry)
                discovery_list.append({
                    "item": item,
                    "params": {"_item_key": item_id},
                    "metrics": ["state"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d access sensors" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # Check mode
    item = params.get("item", "")
    # Get _item_key for lookup (compatibility with discovered services)
    item_key = params.get("_item_key", item)
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Re-fetch the specific sensor data for this item
    res_desc = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".6"
    ], mutates=False)
    res_status = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".7"
    ], mutates=False)
    res_delay = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".8"
    ], mutates=False)
    res_sens = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, DETECT_OID_DESC + ".9"
    ], mutates=False)
    
    oid_to_val_desc = _parse_snmp_output(res_desc.stdout)
    oid_to_val_status = _parse_snmp_output(res_status.stdout)
    oid_to_val_delay = _parse_snmp_output(res_delay.stdout)
    oid_to_val_sens = _parse_snmp_output(res_sens.stdout)
    
    # Locate the sensor by _item_key
    entry = None
    for oid, val in oid_to_val_desc.items():
        parts = oid.split(".")
        if len(parts) >= 14 and parts[-2] == item_key:
            entry = {
                "DescName": val,
                "Status": oid_to_val_status.get(oid.replace(".6.", ".7."), ""),
                "Delay": oid_to_val_delay.get(oid.replace(".6.", ".8."), ""),
                "Sensitivity": oid_to_val_sens.get(oid.replace(".6.", ".9."), "")
            }
            break
    
    if entry == None or len(entry) == 0:
        return {
            "changed": False,
            "msg": "access sensor not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state from Status
    state_readable = entry.get("Status", "Unknown")
    if state_readable == "Closed":
        state = "OK"
    elif state_readable == "Open":
        state = "WARN"
    else:
        state = "CRIT"
    
    # Build summary message (Checkmk style)
    desc = entry.get("DescName", item)
    delay = entry.get("Delay", "")
    sensitivity = entry.get("Sensitivity", "")
    
    msg = "%s: %s" % (desc, state_readable)
    if delay:
        msg = msg + ", Delay: %s" % delay
    if sensitivity:
        msg = msg + ", Sensitivity: %s" % sensitivity
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }


def get_item(id_, params, sensor):
    if params.get("use_sensor_description", False):
        loc = sensor.get("_location_", "")
        idx = sensor.get("_index_", "")
        desc = sensor.get("DescName", "")
        return "%s-%s %s" % (loc, idx, desc)
    return id_


def _parse_snmp_output(output):
    result = {}
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Format: "oid index = TYPE: value"
        eq_pos = stripped.find("=")
        if eq_pos == -1:
            continue
        oid_part = stripped[:eq_pos].strip()
        val_part = stripped[eq_pos + 1:].strip()
        # Remove TYPE: prefix
        colon_pos = val_part.find(":")
        if colon_pos != -1:
            val_part = val_part[colon_pos + 1:].strip()
        result[oid_part] = val_part
    return result
