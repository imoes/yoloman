def main(ctx, params):
    # Step 1: Get serverStatus via mongosh
    res = ctx.run(["mongosh", "--quiet", "--eval", "db.adminCommand({serverStatus:1})", "--norc"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to get MongoDB serverStatus",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "mongosh command failed"}
        }
    
    # Step 2: Parse JSON - guard instead of try/except
    if not res.stdout:
        return {
            "changed": False,
            "msg": "Failed to parse MongoDB serverStatus JSON",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "empty output"}
        }
    
    # Guard: check if output starts with '{' to avoid JSON decode error
    if res.stdout.find("{") != 0:
        return {
            "changed": False,
            "msg": "Failed to parse MongoDB serverStatus JSON",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "invalid JSON format"}
        }
    
    data = json.decode(res.stdout)
    
    # Extract opcounters and opcountersRepl
    server_status = data.get("serverStatus", {})
    opcounters = server_status.get("opcounters", {})
    opcounters_repl = server_status.get("opcountersRepl", {})
    
    # Build section in the same format as parse_mongodb_counters
    section = {}
    if opcounters:
        section["opcounters"] = opcounters
    if opcounters_repl:
        section["opcountersRepl"] = opcounters_repl
    
    # Step 3: Discovery
    if params.get("_discover"):
        items = []
        if "opcounters" in section:
            metrics_list = []
            for k in opcounters.keys():
                metrics_list.append(k + "_ops")
            items.append({
                "item": "Operations",
                "params": {},
                "metrics": metrics_list
            })
        if "opcountersRepl" in section:
            metrics_list = []
            for k in opcounters_repl.keys():
                metrics_list.append(k + "_ops")
            items.append({
                "item": "Replica Operations",
                "params": {},
                "metrics": metrics_list
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items}
        }
    
    # Step 4: Check mode
    item = params.get("item", "")
    item_map = {"Operations": "opcounters", "Replica Operations": "opcountersRepl"}
    
    if item not in item_map:
        return {
            "changed": False,
            "msg": "Unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    section_key = item_map[item]
    if section_key not in section:
        return {
            "changed": False,
            "msg": "Item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Section key '" + section_key + "' not in data"}
        }
    
    data_item = section[section_key]
    
    # Build metrics: for each counter, metric name is "{counter}_ops", value is absolute count
    metrics = {}
    details_parts = []
    for counter_name in data_item.keys():
        value = data_item.get(counter_name)
        # Guard: ensure value is an integer
        if value == None:
            value = 0
        metrics[counter_name + "_ops"] = value
        details_parts.append(counter_name + ": " + str(value))
    
    msg = item + ": " + ", ".join(details_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": ""
        }
    }