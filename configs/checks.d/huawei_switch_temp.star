# ===== Starlark translation: huawei_switch_temp =====

# Top-level constants for entity matching
_ENTITY_NAME_START = "mpu board"

def _parse_snmp_output(entities_lines, values_lines):
    """
    Parse the SNMP output into a dict of items.
    Returns: {item_name: {"stack_member": int, "value": float or None}}
    """
    result = {}
    stack_member_number = 0
    entities_per_member = {}
    
    # Group entities by stack member
    for line in entities_lines:
        if len(line) < 2:
            continue
        # line = [physical_index, entity_name]
        entity_name = line[1].lower() if line[1] else ""
        physical_index = line[0]
        
        # each mpu board signals the beginning of a new stack member
        if entity_name.startswith(_ENTITY_NAME_START):
            stack_member_number += 1
            entities_per_member[stack_member_number] = []
        
        if entity_name.startswith(_ENTITY_NAME_START):
            value = None
            for val_line in values_lines:
                if len(val_line) >= 2 and val_line[0] == physical_index:
                    value = val_line[1]
            
            if stack_member_number > 0:
                entities_per_member[stack_member_number].append({
                    "physical_index": physical_index,
                    "stack_member": stack_member_number,
                    "value": value
                })
    
    # Build item dict with {stack_member}/{entity_idx} format
    for member_number, entities in entities_per_member.items():
        for entity_idx, entity in enumerate(entities):
            item_name = str(member_number)
            # add sub index since multiple entities per stack member are possible
            item_name += "/" + str(entity_idx + 1)
            result[item_name] = entity
    
    return result


def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        # Fetch both SNMP trees needed by the check
        res_entities = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), ".1.3.6.1.2.1.47.1.1.1.1"
        ], mutates=False)
        
        res_values = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1"
        ], mutates=False)
        
        # Parse SNMP lines: "OID = TYPE: value"
        def parse_snmp_line(line):
            # Split on " = " to separate OID and value part
            parts = line.strip().split(" = ", 1)
            if len(parts) < 2:
                return None, None
            oid = parts[0].strip()
            value_part = parts[1].strip()
            # Split value_part on ": " to get type and value
            val_parts = value_part.split(": ", 1)
            if len(val_parts) < 2:
                return oid, value_part  # return raw if no type
            return oid, val_parts[1].strip()  # return value only
        
        # Extract entities table lines (base OID: .1.3.6.1.2.1.47.1.1.1.1)
        entities_lines = []
        for line in res_entities.stdout.splitlines():
            oid, val = parse_snmp_line(line)
            if oid == None:
                continue
            # We need both physical index (oid ends with .1) and name (oid ends with .2)
            # Extract numeric part after last dot (OID end)
            end_oid = oid.rsplit('.', 1)[-1]
            if end_oid == '1':
                # Physical index line - collect for next name line
                pass  # will be processed in next loop iteration
            elif end_oid == '2':
                # Name line
                physical_idx = None
                for prev_line in entities_lines:
                    if prev_line[1] == '1' and prev_line[2] == oid.rsplit('.', 1)[0]:
                        physical_idx = prev_line[0]
                        break
                if physical_idx != None:
                    entities_lines.append([physical_idx, val])
                else:
                    # Try to find the physical index by scanning backward
                    for i in range(len(entities_lines) - 1, -1, -1):
                        if entities_lines[i][2] == oid.rsplit('.', 1)[0]:
                            entities_lines.append([entities_lines[i][0], val])
                            break
                # Simpler approach: rebuild from raw data
                # Reset and redo parsing
        
        # Re-parse more carefully - collect all lines and process by index
        entities_raw = []
        for line in res_entities.stdout.splitlines():
            parts = line.strip().split(" = ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            val_parts = value_part.split(": ", 1)
            val = val_parts[1].strip() if len(val_parts) > 1 else value_part
            
            # Extract index from OID (last component after last dot)
            end_idx = oid.rsplit('.', 1)[-1]
            base_oid = oid.rsplit('.', 1)[0]
            entities_raw.append({"oid": oid, "end": end_idx, "base": base_oid, "value": val})
        
        # Build entities table: for each base_oid with end==2, find end==1's value
        entities_lines = []
        idx_map = {}  # map base_oid to physical index
        for entry in entities_raw:
            if entry["end"] == "1":
                idx_map[entry["base"]] = entry["value"]
            elif entry["end"] == "2":
                physical_idx = idx_map.get(entry["base"])
                if physical_idx != None:
                    entities_lines.append([physical_idx, entry["value"]])
        
        # Parse values table (base OID: .1.3.6.1.4.1.2011.5.25.31.1.1.1.1)
        values_lines = []
        values_raw = []
        for line in res_values.stdout.splitlines():
            parts = line.strip().split(" = ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            val_parts = value_part.split(": ", 1)
            val = val_parts[1].strip() if len(val_parts) > 1 else value_part
            
            # Extract index from OID
            end_idx = oid.rsplit('.', 1)[-1]
            base_oid = oid.rsplit('.', 1)[0]
            values_raw.append({"oid": oid, "end": end_idx, "base": base_oid, "value": val})
        
        # Group by base_oid
        value_map = {}
        for entry in values_raw:
            if entry["end"] == "11":
                value_map[entry["base"]] = entry["value"]
        
        for entry in entities_lines:
            # Find corresponding value
            physical_idx = entry[0]
            val = value_map.get(physical_idx)
            if val != None:
                values_lines.append([physical_idx, val])
        
        # Parse into section
        section = _parse_snmp_output(entities_lines, values_lines)
        
        # Build discovery list
        discovery_list = []
        for item in section:
            entity = section[item]
            if entity and entity.get("value") != None:
                discovery_list.append({
                    "item": item,
                    "params": {"levels": (80.0, 90.0)},
                    "metrics": ["temperature"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    
    # Get SNMP data
    res_entities = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), ".1.3.6.1.2.1.47.1.1.1.1"
    ], mutates=False)
    
    res_values = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1"
    ], mutates=False)
    
    # Parse SNMP lines (same logic as discovery)
    def parse_snmp_line(line):
        parts = line.strip().split(" = ", 1)
        if len(parts) < 2:
            return None, None, None
        oid = parts[0].strip()
        value_part = parts[1].strip()
        val_parts = value_part.split(": ", 1)
        val = val_parts[1].strip() if len(val_parts) > 1 else value_part
        end_idx = oid.rsplit('.', 1)[-1]
        base_oid = oid.rsplit('.', 1)[0]
        return end_idx, base_oid, val
    
    # Build entities mapping
    entities_lines = []
    idx_map = {}
    for line in res_entities.stdout.splitlines():
        end_idx, base_oid, val = parse_snmp_line(line)
        if end_idx == "1":
            idx_map[base_oid] = val
        elif end_idx == "2":
            physical_idx = idx_map.get(base_oid)
            if physical_idx != None:
                entities_lines.append([physical_idx, val])
    
    # Build values mapping
    value_map = {}
    for line in res_values.stdout.splitlines():
        end_idx, base_oid, val = parse_snmp_line(line)
        if end_idx == "11":
            value_map[base_oid] = val
    
    # Construct values_lines
    values_lines = []
    for entry in entities_lines:
        physical_idx = entry[0]
        val = value_map.get(physical_idx)
        if val != None:
            values_lines.append([physical_idx, val])
    
    # Parse into section
    section = _parse_snmp_output(entities_lines, values_lines)
    
    # Check item exists
    if item not in section:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    item_data = section[item]
    if item_data == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value = item_data.get("value")
    
    if value == None or value == "":
        return {
            "changed": False,
            "msg": "no value for sensor " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Convert to float - guard instead of try/except
    temp = float(value) if value.replace(".", "", 1).isdigit() or (value.count("-") <= 1 and value.replace("-", "", 1).replace(".", "", 1).isdigit()) else None
    
    if temp == None:
        return {
            "changed": False,
            "msg": "invalid temperature value: " + value,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Apply thresholds
    warn = params.get("levels", (80.0, 90.0))
    warn_val = warn[0]
    crit_val = warn[1]
    
    if temp >= crit_val:
        state = "CRIT"
    elif temp >= warn_val:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg = "Temperature: %f C" % temp
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }