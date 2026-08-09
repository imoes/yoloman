def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["storeonce_status_cli", "--help"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "storeonce_status_cli not found", "data": {"discovery": [], "host_labels": {}}}
        res = ctx.run(["storeonce_status_cli", "servicesets"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no servicesets data", "data": {"discovery": [], "host_labels": {}}}
        lines = res.stdout.splitlines()
        items = []
        current = None
        block = {}
        for line in lines:
            if line.startswith("[") and line.endswith("]"):
                if current != None and block:
                    items.append(current)
                idx = line[1:-1].strip()
                if not idx.isdigit():
                    continue
                current = idx
                block = {}
            else:
                kv = line.split(None, 1)
                if len(kv) == 2 and current != None:
                    block[kv[0].strip()] = kv[1].strip()
        if current != None and block:
            items.append(current)
        if not items:
            return {"changed": False, "msg": "no servicesets data", "data": {"discovery": [], "host_labels": {}}}
        discovery = [{"item": it, "params": {"warn": 80, "crit": 90}, "metrics": ["used_percent", "size", "used", "free"], "service_labels": {}} for it in items]
        host_labels = {}
        for it_block in [block]:
            if "Product Class" in it_block:
                host_labels["cmk/storeonce_product_class"] = it_block["Product Class"]
        return {"changed": False, "msg": "discovered %d servicesets" % len(discovery), "data": {"discovery": discovery, "host_labels": host_labels}}
    item = params.get("item", "")
    res = ctx.run(["storeonce_status_cli", "servicesets"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no servicesets data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    blocks = {}
    current = None
    block = {}
    for line in lines:
        if line.startswith("[") and line.endswith("]"):
            if current != None:
                blocks[current] = block
            idx = line[1:-1].strip()
            if not idx.isdigit():
                continue
            current = idx
            block = {}
        else:
            kv = line.split(None, 1)
            if len(kv) == 2 and current != None:
                block[kv[0].strip()] = kv[1].strip()
    if current != None:
        blocks[current] = block
    values = None
    for k, v in blocks.items():
        if k == item:
            values = v
            break
    if values == None:
        return {"changed": False, "msg": "no such serviceset: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    capacity = 0
    free = 0
    for key in ["Capacity in bytes", "localCapacityBytes", "combinedCapacityBytes"]:
        if key in values:
            capacity = int(values[key])
            break
    for key in ["Free Space in bytes", "localFreeBytes", "combinedFreeBytes"]:
        if key in values:
            free = int(values[key])
            break
    if capacity == 0:
        return {"changed": False, "msg": "no capacity data for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    used = capacity - free
    used_percent = (used * 100 / capacity) if capacity > 0 else 0
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    details = "Capacity: %d bytes, Used: %d bytes, Free: %d bytes, Used: %d%%" % (capacity, used, free, int(used_percent))
    if "Overall Status" in values and "Overall Health" in values:
        details += ", Overall Status: %s, Overall Health: %s" % (values["Overall Status"], values["Overall Health"])
    if "ServiceSet Alias" in values:
        msg = "Alias: %s, Size: %d bytes, Age: %d m" % (values["ServiceSet Alias"], used, 0)
    elif "ServiceSet Name" in values:
        msg = "Name: %s, Size: %d bytes, Age: %d m" % (values["ServiceSet Name"], used, 0)
    else:
        msg = "Size: %d bytes, Used: %d%%" % (capacity, int(used_percent))
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": int(used_percent), "size": capacity, "used": used, "free": free},
            "details": details,
        },
    }