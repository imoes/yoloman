# ===== module constants (SNMP OIDs and state mapping) =====
OID_BASE_DISKS = ".1.3.6.1.4.1.19746.1.6.1.1.1"
OID_BASE_BUSY = ".1.3.6.1.4.1.19746.1.6.2.1.1"

STATE_TABLE = {
    "1": ("Operational", "OK"),
    "2": ("Unknown", "UNKNOWN"),
    "3": ("Absent", "WARN"),
    "4": ("Failed", "CRIT"),
    "5": ("Spare", "OK"),
    "6": ("Available", "OK"),
    "10": ("System", "OK"),
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            OID_BASE_DISKS,
        ], mutates=False)
        
        lines = res.stdout.splitlines()
        disks = {}
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            if "." in oid_part:
                idx_str = oid_part.rsplit(".", 1)[-1]
                if not idx_str.isdigit():
                    continue
                idx = int(idx_str)
                if idx < 1 or idx > 8:
                    continue
                if ":" in value_part:
                    val = value_part.split(":", 1)[1].strip().strip('"')
                else:
                    val = value_part.strip().strip('"')
                if idx not in disks:
                    disks[idx] = [None] * 8
                disks[idx][idx-1] = val
        
        items_map = {}
        for idx in sorted(disks.keys()):
            row = disks[idx]
            if row[0] == None or row[1] == None:
                continue
            item_name = row[0] + "-" + row[1]
            if item_name not in items_map:
                items_map[item_name] = row
        
        out = []
        for item_name in sorted(items_map.keys()):
            out.append({
                "item": item_name,
                "params": {},
                "metrics": ["busy"]
            })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(out),
            "data": {"discovery": out},
        }

    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_BASE_DISKS,
    ], mutates=False)
    
    busy_res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_BASE_BUSY,
    ], mutates=False)
    
    # Parse main table
    lines = res.stdout.splitlines()
    disks = {}
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if "." in oid_part:
            idx_str = oid_part.rsplit(".", 1)[-1]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            if idx < 1 or idx > 8:
                continue
            if ":" in value_part:
                val = value_part.split(":", 1)[1].strip().strip('"')
            else:
                val = value_part.strip().strip('"')
            if idx not in disks:
                disks[idx] = [None] * 8
            disks[idx][idx-1] = val
    
    # Parse busy table
    busy_list = []
    busy_lines = busy_res.stdout.splitlines()
    for line in busy_lines:
        if "=" not in line:
            continue
        value_part = line.split("=", 1)[1].strip()
        if ":" in value_part:
            val = value_part.split(":", 1)[1].strip()
        else:
            val = value_part.strip()
        busy_list.append(val)
    
    # Search for the item
    found = False
    row = [None] * 8
    for idx in sorted(disks.keys()):
        cur_row = disks[idx]
        if cur_row[0] == None or cur_row[1] == None:
            continue
        if cur_row[0] + "-" + cur_row[1] == item:
            found = True
            row = cur_row
            break
    
    if not found:
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    # Extract values
    disk_name = row[0] if row[0] != None else ""
    slot = row[1] if row[1] != None else ""
    model = row[2] if row[2] != None else ""
    firmware = row[3] if row[3] != None else ""
    serial = row[4] if row[4] != None else ""
    capacity = row[5] if row[5] != None else ""
    dev_state = row[6] if row[6] != None else ""
    end_val = row[7] if row[7] != None else ""
    
    state_str, state_rc = STATE_TABLE.get(dev_state, ("Unknown", "UNKNOWN"))
    
    # Build summary
    summary_parts = [state_str]
    metrics = {}
    
    # Extract busy metric: index = int(line[7].split(".")[1]) - 1
    if end_val != "" and "." in end_val:
        parts_end = end_val.split(".")
        if len(parts_end) >= 2 and parts_end[1].isdigit():
            index = int(parts_end[1]) - 1
            if index >= 0 and index < len(busy_list):
                busy_val = busy_list[index]
                if busy_val.isdigit():
                    summary_parts.append("busy " + busy_val + "%")
                    metrics["busy"] = int(busy_val)
    
    summary = ", ".join(summary_parts)
    model_summary = "Model %s, Firmware %s, Serial %s, Capacity %s" % (
        model,
        firmware,
        serial,
        capacity,
    )
    
    # Map state string to Checkmk state
    if state_rc == "OK":
        state = "OK"
    elif state_rc == "UNKNOWN":
        state = "UNKNOWN"
    elif state_rc == "WARN":
        state = "WARN"
    elif state_rc == "CRIT":
        state = "CRIT"
    else:
        state = "UNKNOWN"
    
    return {
        "changed": False,
        "msg": summary + ", " + model_summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
