def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        ], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid_part = parts[0]
            # Skip non-matching OIDs
            if not oid_part.endswith(".5266"):
                continue
            # Extract base OID suffix
            suffixes = oid_part.split(".")
            base_num = 0
            if len(suffixes) >= 5:
                idx = len(suffixes) - 5
                candidate = suffixes[idx]
                if candidate.lstrip("-").isdigit():
                    base_num = int(candidate)
            item_name = str(base_num // 10)
            items.append(item_name)
        # Deduplicate while preserving order
        seen = set()
        unique_items = []
        for item in items:
            if item not in seen:
                seen.add(item)
                unique_items.append(item)
        discovery = []
        for item in unique_items:
            discovery.append({
                "item": item,
                "params": {"levels": (8, 12)},
                "metrics": ["head_pressure"]
            })
        return {
            "changed": False,
            "msg": "discovered %d compressors" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    item_num = int(item) if item.isdigit() else 1
    oid_index = item_num * 10
    oid_full = ".1.3.6.1.4.1.476.1.42.3.9.20.1.%d.1.2.1.5266" % oid_index
    
    res_value = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, oid_full
    ], mutates=False)
    
    if res_value.rc != 0 or not res_value.stdout.strip():
        return {
            "changed": False,
            "msg": "no data for compressor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    line = res_value.stdout.strip()
    idx = line.find(" = ")
    if idx == -1:
        return {
            "changed": False,
            "msg": "could not parse output for compressor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = line[idx + 3:].strip()
    tokens = value_str.split()
    if len(tokens) < 1:
        return {
            "changed": False,
            "msg": "invalid value format for compressor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    val_str = tokens[0].strip('"\'')
    value = 0.0
    if val_str.replace(".", "").replace("-", "").isdigit() and val_str.count(".") <= 1:
        value = float(val_str)
    else:
        return {
            "changed": False,
            "msg": "invalid value format for compressor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    unit = " ".join(tokens[1:]) if len(tokens) > 1 else "deg C"
    
    levels = params.get("levels", (8, 12))
    warn = levels[0]
    crit = levels[1]
    
    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": "Head pressure: %f %s" % (value, unit),
        "data": {
            "state": state,
            "metrics": {"head_pressure": value},
            "details": ""
        }
    }