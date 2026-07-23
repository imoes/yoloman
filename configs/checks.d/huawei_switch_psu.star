def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res1 = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.47.1.1.1.1.7"
        ], mutates=False)
        res2 = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.2"
        ], mutates=False)
        
        name_lines = res1.stdout.split("\n") if res1.stdout else []
        status_lines = res2.stdout.split("\n") if res2.stdout else []
        
        index_to_name = {}
        for line in name_lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip().strip('"')
            index = oid_part.rsplit(".", 1)[-1]
            if "power card" in value_part.lower():
                index_to_name[index] = value_part
        
        index_to_status = {}
        for line in status_lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            index = oid_part.rsplit(".", 1)[-1]
            index_to_status[index] = value_part
        
        power_card_indices = []
        for idx in index_to_name:
            if idx in index_to_status and index_to_status[idx].isdigit():
                power_card_indices.append(idx)
        
        discovered_items = []
        for i in range(len(power_card_indices)):
            item = "1/" + str(i + 1)
            discovered_items.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovered_items),
            "data": {"discovery": discovered_items}
        }
    
    # Check mode
    item = params.get("item", "")
    
    res1 = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.47.1.1.1.1.7"
    ], mutates=False)
    res2 = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.2"
    ], mutates=False)
    
    name_lines = res1.stdout.split("\n") if res1.stdout else []
    status_lines = res2.stdout.split("\n") if res2.stdout else []
    
    power_card_indices = []
    for line in name_lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1].strip().strip('"')
        if "power card" in value_part.lower():
            oid_part = parts[0].strip()
            idx = oid_part.rsplit(".", 1)[-1]
            power_card_indices.append(idx)
    
    # Parse item to extract number (e.g., "1/2" -> 2)
    parts_item = item.split("/")
    if len(parts_item) != 2 or not parts_item[1].isdigit():
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    item_num = int(parts_item[1])
    
    if item_num <= 0 or item_num > len(power_card_indices):
        return {
            "changed": False,
            "msg": "power supply not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    idx = power_card_indices[item_num - 1]
    status_value = None
    for line in status_lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        index = oid_part.rsplit(".", 1)[-1]
        if index == idx:
            status_value = parts[1].strip()
            break
    
    if status_value == None:
        return {
            "changed": False,
            "msg": "no status for power supply: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state_map = {
        "1": "notSupported",
        "2": "disabled",
        "3": "enabled",
        "4": "offline"
    }
    status_text = state_map.get(status_value, "unknown (%s)" % status_value)
    state = "OK" if status_value == "3" else "CRIT"
    
    return {
        "changed": False,
        "msg": "State: " + status_text,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }