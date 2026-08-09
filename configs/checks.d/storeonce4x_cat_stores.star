def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                       "-On", params.get("host", "localhost"), "1.3.6.1.4.1.23223.2.3.1.1.2.1.1"],
                      mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + res.stderr.strip(),
                    "data": {"discovery": []}}
        stores = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1].strip().strip('"')
            suffix = oid[len("1.3.6.1.4.1.23223.2.3.1.1.2.1.1"):]
            idx_parts = suffix.split(".")
            if len(idx_parts) >= 2 and idx_parts[0] == "":
                continue
            idx_parts = [p for p in suffix.split(".") if p != ""]
            if len(idx_parts) < 2:
                continue
            store_idx = idx_parts[0]
            col = idx_parts[1] if len(idx_parts) > 1 else ""
            if store_idx not in stores:
                stores[store_idx] = {}
            stores[store_idx]["idx"] = store_idx
            stores[store_idx]["col_" + col] = value

        discovery = []
        for store_idx, cols in stores.items():
            store_id = cols.get("col_1", "")
            store_name = cols.get("col_2", "")
            if not store_name:
                continue
            item = "%s - %s" % (store_id, store_name)
            metrics = ["dedup_rate", "file_count"]
            discovery.append({"item": item, "params": {}, "metrics": metrics})

        return {"changed": False,
                "msg": "discovered %d catalyst stores" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-Oqn", "-On", params.get("host", "localhost"),
                   "1.3.6.1.4.1.23223.2.3.1.1.2.1"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "snmpwalk not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_stores = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].strip().strip('"')
        suffix = oid[len("1.3.6.1.4.1.23223.2.3.1.1.2.1"):]
        idx_parts = [p for p in suffix.split(".") if p != ""]
        if len(idx_parts) < 2:
            continue
        store_idx = idx_parts[0]
        col = idx_parts[1]
        found = False
        for s in raw_stores:
            if s["idx"] == store_idx:
                s["cols"][col] = value
                found = True
                break
        if not found:
            raw_stores.append({"idx": store_idx, "cols": {col: value}})

    store = None
    for s in raw_stores:
        cols = s["cols"]
        store_id = cols.get("1", "")
        store_name = cols.get("2", "")
        candidate = "%s - %s" % (store_id, store_name)
        if candidate == item:
            store = cols
            break
    if store == None:
        return {"changed": False, "msg": "no such catalyst store: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    store_status_str = store.get("3", "unknown")
    dedup_ratio = float(store.get("4", 0)) if store.get("4", "").replace(".", "", 1).isdigit() else 0.0
    user_bytes = float(store.get("5", 0)) if store.get("5", "").replace(".", "", 1).isdigit() else 0.0
    num_items = int(store.get("6", 0)) if store.get("6", "").isdigit() else 0
    size_enabled = store.get("7", "0") == "1"
    size_quota_bytes = float(store.get("8", 0)) if store.get("8", "").replace(".", "", 1).isdigit() else 0.0
    disk_bytes = float(store.get("9", 0)) if store.get("9", "").replace(".", "", 1).isdigit() else 0.0
    description = store.get("10", "")

    metrics = {}
    metrics["dedup_rate"] = dedup_ratio
    metrics["file_count"] = num_items

    status_int = int(store.get("3_int", 2)) if store.get("3_int", "2").isdigit() else 2
    state = "OK" if status_int == 2 else "CRIT"

    msg = "Status: %s, Dedup ratio: %f, Files: %d" % (store_status_str, dedup_ratio, num_items)
    if size_enabled:
        mega = 1024 * 1024
        avail_mb = size_quota_bytes / mega
        used_mb = disk_bytes / mega
        details = "Description: %s\nUserBytes: %d\nDedup ratio: %f\nFiles: %d\nSize available: %f MB\nSize used: %f MB" % (
            description, int(user_bytes), dedup_ratio, num_items, avail_mb, used_mb)
    else:
        details = "Description: %s\nUserBytes: %d\nDedup ratio: %f\nFiles: %d" % (
            description, int(user_bytes), dedup_ratio, num_items)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}