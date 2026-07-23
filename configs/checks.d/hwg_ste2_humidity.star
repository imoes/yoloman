# ===== module: hwg_ste2_humidity.star =====
# Checkmk check: hwg_ste2_humidity (read-only Starlark translation)
# Source: Checkmk plugin for HWG STE2 humidity sensors via SNMP

def _parse_snmp_lines(lines):
    """Parse SNMP walk output lines into a list of [index, descr, status, value, unit]"""
    result = []
    for line in lines:
        # Expected format: .1.3.6.1.4.1.21796.4.1.3.1.1.1 = STRING:"..." or similar
        # We extract the value portion after '=' and strip quotes for strings
        eq_idx = line.find("=")
        if eq_idx < 0:
            continue
        oid_part = line[:eq_idx].strip()
        val_part = line[eq_idx + 1:].strip()
        
        # Determine index from OID (last numeric component after last dot)
        last_dot = oid_part.rfind(".")
        if last_dot < 0:
            continue
        index = oid_part[last_dot + 1:].strip()
        
        # Process value part based on type prefix
        val_stripped = val_part.strip()
        if val_stripped.startswith("STRING:"):
            value = val_stripped[7:].strip()
            # Remove surrounding quotes if present
            if value.startswith("\"") and value.endswith("\""):
                value = value[1:-1]
            result.append([index, value])
        elif val_stripped.startswith("INTEGER:"):
            value = val_stripped[8:].strip()
            result.append([index, value])
        elif val_stripped.startswith("Counter32:"):
            value = val_stripped[10:].strip()
            result.append([index, value])
        elif val_stripped.startswith("Gauge32:"):
            value = val_stripped[8:].strip()
            result.append([index, value])
        else:
            # Treat as plain value
            result.append([index, val_stripped])
    
    # Group by index (every 5 entries form a record)
    records = []
    for i in range(0, len(result), 5):
        if i + 4 < len(result):
            # Pad if incomplete (shouldn't happen but defensive)
            record = result[i:i+5]
            while len(record) < 5:
                record.append(["", ""])
            records.append([r[1] for r in record])
    
    return records


# Map unit codes to labels
map_units = {"1": "c", "2": "f", "3": "k", "4": "%"}

# Map device status codes to names
map_dev_states = {
    "0": "invalid",
    "1": "normal",
    "2": "out of range low",
    "3": "out of range high",
    "4": "alarm low",
    "5": "alarm high"
}


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Walk the hwg_humidity SNMP tree
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.21796.4.1.3.1"
        
        # Fetch all required OIDs in one walk (base + 1-4)
        oids_to_fetch = [
            base_oid + ".1",  # 1 = descr
            base_oid + ".2",  # 2 = sensorstatus
            base_oid + ".3",  # 3 = current
            base_oid + ".4",  # 4 = unit
            base_oid + ".7"   # 7 = dev_status (additional field)
        ]
        
        # Perform a single snmpwalk per OID then process
        all_lines = []
        for oid in oids_to_fetch:
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
            if res.rc != 0:
                return {"changed": False, "msg": "SNMP error on " + oid + ": " + res.stderr,
                        "data": {"discovery": []}}
            lines = res.stdout.splitlines()
            if len(lines) > 0:
                all_lines.extend(lines)
        
        # Parse all lines into records
        raw_records = _parse_snmp_lines(all_lines)
        
        # Process records (group by index)
        section = {}
        for record in raw_records:
            if len(record) < 5:
                continue
            index = record[0]
            descr = record[1]
            sensorstatus = record[2]
            current = record[3]
            unit = record[4]
            
            # Parse humidity (only if sensorstatus != 0 and unit == "%")
            if sensorstatus != "0" and map_units.get(unit, "") == "%":
                # Check if current is a valid number
                if current.replace(".", "").replace("-", "").isdigit():
                    humidity = float(current)
                else:
                    humidity = None
                
                if humidity != None:
                    section[index] = {
                        "descr": descr,
                        "humidity": humidity,
                        "dev_status_name": map_dev_states.get(sensorstatus, "n.a."),
                        "dev_status": sensorstatus
                    }
        
        # Build discovery result: one service per humidity sensor
        discovery = []
        for item, attrs in section.items():
            if attrs.get("humidity") != None:
                discovery.append({
                    "item": item,
                    "params": {"levels": [60.0, 70.0]},
                    "metrics": ["humidity"]
                })
        
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode (single item)
    item = params.get("item", "")
    warn, crit = params.get("levels", [60.0, 70.0])
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.21796.4.1.3.1"
    
    # Fetch all required OIDs for the specific item
    oids_to_fetch = [
        base_oid + ".1." + item,  # descr
        base_oid + ".2." + item,  # sensorstatus
        base_oid + ".3." + item,  # current
        base_oid + ".4." + item,  # unit
        base_oid + ".7." + item   # dev_status
    ]
    
    all_lines = []
    for oid in oids_to_fetch:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP error: " + res.stderr,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        lines = res.stdout.splitlines()
        if len(lines) > 0:
            all_lines.extend(lines)
    
    # Parse lines into record
    raw_records = _parse_snmp_lines(all_lines)
    
    if not raw_records or len(raw_records[0]) < 5:
        return {"changed": False, "msg": "no sensor data found for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    record = raw_records[0]
    if len(record) < 5:
        return {"changed": False, "msg": "incomplete sensor data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    descr = record[1]
    sensorstatus = record[2]
    current = record[3]
    unit = record[4]
    
    # Parse humidity (only if sensorstatus != 0 and unit == "%")
    humidity = None
    if sensorstatus != "0" and map_units.get(unit, "") == "%":
        # Check if current is a valid number
        if current.replace(".", "").replace("-", "").isdigit():
            humidity = float(current)
        else:
            humidity = None
    
    # Determine state and message
    if humidity == None:
        return {"changed": False, "msg": "no humidity data available for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Check thresholds: upper levels
    state = "CRIT" if humidity >= crit else ("WARN" if humidity >= warn else "OK")
    
    # Build status message
    dev_status_name = map_dev_states.get(sensorstatus, "n.a.")
    msg = "Humidity: %f %% " % humidity + ("(OK)" if state == "OK" else ("(WARN)" if state == "WARN" else "(CRIT)"))
    if descr:
        msg += ", Description: " + descr
    msg += ", Status: " + dev_status_name
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"humidity": humidity}, "details": ""}}