def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.232.1.2.2.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}
        
        items = []
        # Parse snmpwalk output: OID = TYPE: value
        current_index = ""
        current_slot = ""
        current_name = ""
        current_status = ""
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Split into OID and value part
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            # Extract value after type indicator (e.g., "STRING:" or "INTEGER:")
            value = value_part
            for prefix in ["STRING:", "INTEGER:", "OctetString:"]:
                if value.startswith(prefix):
                    value = value[len(prefix):].strip().strip('"')
                    break
            
            # Map OID suffix to field
            suffix = oid.rsplit(".", 1)[-1] if "." in oid else ""
            if oid.endswith(".1"):
                current_index = value
            elif oid.endswith(".2"):
                current_slot = value
            elif oid.endswith(".3"):
                current_name = value.replace("\x00", r"\x00")
            elif oid.endswith(".6"):
                current_status = value
                # All fields collected, yield item
                if current_index and current_slot and current_name:
                    items.append({
                        "item": current_name,
                        "params": {},
                        "metrics": []
                    })
                    current_index = ""
                    current_slot = ""
                    current_name = ""
                    current_status = ""
        
        return {
            "changed": False,
            "msg": "discovered %d CPUs" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.232.1.2.2.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpwalk output to find matching CPU
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        
        oid = parts[0].strip()
        value_part = parts[1].strip()
        value = value_part
        for prefix in ["STRING:", "INTEGER:", "OctetString:"]:
            if value.startswith(prefix):
                value = value[len(prefix):].strip().strip('"')
                break
        
        # We need to reconstruct the CPU record from the four OIDs
        # Process line by line and collect fields as we go
        pass  # We'll handle this below with a different parsing strategy
    
    # Let's restructure parsing: collect all lines, then group by index
    lines = res.stdout.splitlines()
    cpu_data = {}
    current_index = ""
    current_slot = ""
    current_name = ""
    current_status = ""
    
    for line in lines:
        if not line.strip():
            continue
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        
        oid = parts[0].strip()
        value_part = parts[1].strip()
        value = value_part
        for prefix in ["STRING:", "INTEGER:", "OctetString:"]:
            if value.startswith(prefix):
                value = value[len(prefix):].strip().strip('"')
                break
        
        # Map OID suffix to field
        if oid.endswith(".1"):
            if current_index:
                # Save previous record
                if current_name.replace("\x00", r"\x00") == item:
                    return format_result(current_index, current_slot, current_name, current_status)
                current_index = ""
                current_slot = ""
                current_name = ""
                current_status = ""
            current_index = value
        elif oid.endswith(".2"):
            current_slot = value
        elif oid.endswith(".3"):
            current_name = value.replace("\x00", r"\x00")
        elif oid.endswith(".6"):
            current_status = value
            # All fields collected for this CPU
            if current_name == item:
                return format_result(current_index, current_slot, current_name, current_status)
            # Reset for next CPU
            current_index = ""
            current_slot = ""
            current_name = ""
            current_status = ""
    
    # Also check the last collected CPU if we didn't find a match earlier
    if current_name == item:
        return format_result(current_index, current_slot, current_name, current_status)
    
    return {
        "changed": False,
        "msg": "CPU %s not found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }


def format_result(index, slot, name, status):
    # Map status value to Checkmk state
    status_map = {
        "1": "unknown",
        "2": "ok",
        "3": "degraded",
        "4": "failed",
        "5": "disabled"
    }
    snmp_status = status_map.get(status, "unknown")
    
    # Checkmk status map from lib
    state_map = {
        "unknown": "UNKNOWN",
        "other": "UNKNOWN",
        "ok": "OK",
        "degraded": "CRIT",
        "failed": "CRIT",
        "disabled": "WARN"
    }
    state = state_map.get(snmp_status, "UNKNOWN")
    
    return {
        "changed": False,
        "msg": 'CPU%s "%s" in slot %s is in state "%s"' % (index, name, slot, snmp_status),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }