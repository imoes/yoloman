def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            ".1.3.6.1.4.1.6574.2.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        lines = res.stdout.splitlines()
        rows = []
        current_index = None
        row_data = [None] * 6
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            last_dot = oid_full.rfind(".")
            if last_dot == -1:
                continue
            index_str = oid_full[last_dot + 1:]
            index = int(index_str) if index_str.isdigit() else -1
            if index < 0:
                continue
            suffix = oid_full.rsplit(".", 1)[1]
            col = int(suffix) if suffix.isdigit() else -1
            if col < 2 or col > 13:
                continue
            col_map = {2: 0, 3: 1, 5: 2, 6: 3, 7: 4, 13: 5}
            if col in col_map:
                if current_index != index:
                    if current_index != None and None not in row_data:
                        rows.append(row_data[:])
                    current_index = index
                    row_data = [None] * 6
                row_data[col_map[col]] = value
        if current_index != None and None not in row_data:
            rows.append(row_data[:])
        items = []
        for row in rows:
            if len(row) < 1 or row[0] == None:
                continue
            item = row[0]
            items.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    if item == None:
        item = ""
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host,
        ".1.3.6.1.4.1.6574.2.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    lines = res.stdout.splitlines()
    rows = []
    current_index = None
    row_data = [None] * 6
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        last_dot = oid_full.rfind(".")
        if last_dot == -1:
            continue
        index_str = oid_full[last_dot + 1:]
        index = int(index_str) if index_str.isdigit() else -1
        if index < 0:
            continue
        suffix = oid_full.rsplit(".", 1)[1]
        col = int(suffix) if suffix.isdigit() else -1
        if col < 2 or col > 13:
            continue
        col_map = {2: 0, 3: 1, 5: 2, 6: 3, 7: 4, 13: 5}
        if col in col_map:
            if current_index != index:
                if current_index != None and None not in row_data:
                    rows.append(row_data[:])
                current_index = index
                row_data = [None] * 6
            row_data[col_map[col]] = value
    if current_index != None and None not in row_data:
        rows.append(row_data[:])
    disk_row = None
    for row in rows:
        if len(row) > 0 and row[0] == item:
            disk_row = row
            break
    if disk_row == None:
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    disk_id = disk_row[0] if len(disk_row) > 0 else ""
    model = disk_row[1] if len(disk_row) > 1 else ""
    state_str = disk_row[2] if len(disk_row) > 2 else ""
    temperature_str = disk_row[3] if len(disk_row) > 3 else ""
    role = disk_row[4] if len(disk_row) > 4 else ""
    health_str = disk_row[5] if len(disk_row) > 5 else ""
    state = 1
    if state_str.isdigit():
        state = int(state_str)
    temperature = 0.0
    if temperature_str != "" and temperature_str.isdigit():
        temperature = float(temperature_str)
    health = None
    if health_str.isdigit():
        health = int(health_str)
    alloc_state = "UNKNOWN"
    alloc_text = "unknown allocation status"
    if state == 1 or state == 2:
        alloc_state = "OK"
        alloc_text = "OK"
    elif state == 3:
        alloc_state = "WARN"
        alloc_text = "not initialized"
    elif state == 4:
        alloc_state = "CRIT"
        alloc_text = "system partition failed"
    elif state == 5:
        alloc_state = "CRIT"
        alloc_text = "crashed"
    if role == "hotspare" or role == "ssd_cache":
        if state == 3:
            alloc_state = "OK"
            alloc_text = "disk is " + role
    health_state = "UNKNOWN"
    health_text = "unknown health"
    if health == 1:
        health_state = "OK"
        health_text = "Normal"
    elif health == 2:
        health_state = "WARN"
        health_text = "Warning"
    elif health == 3:
        health_state = "CRIT"
        health_text = "Critical"
    elif health == 4:
        health_state = "CRIT"
        health_text = "Failing"
    elif health == None:
        health_state = "OK"
        health_text = "Not provided (available with DSM 7.1 and above)"
    overall_state = alloc_state
    if health_state == "CRIT" or overall_state == "CRIT":
        overall_state = "CRIT"
    elif health_state == "WARN" or overall_state == "WARN":
        overall_state = "WARN"
    temp_text = "Temperature: %f C" % temperature
    msg = "%s | Allocation status: %s | Model: %s | %s" % (
        alloc_text, alloc_text, model, temp_text
    )
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {"temperature": temperature},
            "details": "Model: %s, Health: %s" % (model, health_text)
        }
    }