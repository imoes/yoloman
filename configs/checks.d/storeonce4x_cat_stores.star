def _bytes_human(n):
    if n >= 1073741824:
        return "%f GB" % (n / 1073741824.0)
    if n >= 1048576:
        return "%f MB" % (n / 1048576.0)
    if n >= 1024:
        return "%f KB" % (n / 1024.0)
    return "%d B" % n

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "admin")
    password = params.get("password", "")

    res = ctx.run(
        ["curl", "-sk", "-u", username + ":" + password,
         "-H", "Accept: application/json",
         "https://" + host + "/rest/storeonce/v4/cat/stores"],
        mutates=False,
    )

    if res.rc != 0 or not res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "failed to fetch stores: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)
    members = data.get("members", [])

    stores = {}
    for elem in members:
        key = "%d - %s" % (int(elem["id"]), str(elem["name"]))
        stores[key] = elem

    if params.get("_discover"):
        out = []
        for k in stores:
            out.append({
                "item": k,
                "params": {"warn": 80, "crit": 90},
                "metrics": ["dedup_rate", "file_count"],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    store = stores.get(item)
    if store == None:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mega = 1024.0 * 1024.0
    store_status = store.get("storeStatus", -1)
    store_status_str = store.get("storeStatusString", "unknown")
    dedup_ratio = float(store.get("dedupeRatio", 0))
    quota_bytes = store.get("sizeOnDiskQuotaBytes", 0)
    disk_bytes = store.get("diskBytes", 0)
    user_bytes = store.get("userBytes", 0)
    num_items = store.get("numItems", 0)
    quota_enabled = store.get("sizeOnDiskQuotaEnabled", False)
    description = store.get("description", "")

    size_available_mb = quota_bytes / mega
    size_used_mb = disk_bytes / mega

    status_state = "OK" if store_status == 2 else "CRIT"

    disk_state = "OK"
    used_percent = 0.0
    if quota_enabled and size_available_mb > 0:
        used_percent = (size_used_mb / size_available_mb) * 100.0
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)
        if used_percent >= crit:
            disk_state = "CRIT"
        elif used_percent >= warn:
            disk_state = "WARN"

    state = "OK"
    if status_state == "CRIT" or disk_state == "CRIT":
        state = "CRIT"
    elif disk_state == "WARN":
        state = "WARN"

    parts = ["Status: %s" % store_status_str]
    if quota_enabled:
        parts.append("%f%% used" % used_percent)
    parts.append("UserBytes: %s" % _bytes_human(user_bytes))
    parts.append("Dedup ratio: %f" % dedup_ratio)
    parts.append("Files: %d" % num_items)

    metrics = {
        "dedup_rate": dedup_ratio,
        "file_count": float(num_items),
    }
    if quota_enabled:
        metrics["used_percent"] = used_percent

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "Description: " + description,
        },
    }