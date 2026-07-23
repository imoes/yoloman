DFLT_HEADER = [
    "id", "name", "status", "mdisk_count", "vdisk_count", "capacity",
    "extent_size", "free_capacity", "virtual_capacity", "used_capacity",
    "real_capacity", "overallocation", "warning", "easy_tier",
    "easy_tier_status", "compression_active", "compression_virtual_capacity",
    "compression_compressed_capacity", "compression_uncompressed_capacity",
]

SIZE_SUFFIXES = ["EB", "PB", "TB", "GB", "MB"]

STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _to_mb(size):
    if not size:
        return 0.0
    s = size.strip()
    suffix = ""
    for sfx in SIZE_SUFFIXES:
        if s.endswith(sfx):
            suffix = sfx
            break
    num_str = s[:-len(suffix)] if suffix else s
    if not num_str:
        return 0.0
    num = float(num_str)
    if suffix == "EB":
        return num * 1024.0 * 1024.0 * 1024.0 * 1024.0
    if suffix == "PB":
        return num * 1024.0 * 1024.0 * 1024.0
    if suffix == "TB":
        return num * 1024.0 * 1024.0
    if suffix == "GB":
        return num * 1024.0
    return num

def _fetch_pools(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "admin")
    res = ctx.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
         "-l", user, host, "lsmdiskgrp", "-delim", ":"],
        mutates=False,
    )
    if res.rc != 0:
        return None, "SSH failed (rc=%d): %s" % (res.rc, res.stderr.strip())
    pools = {}
    header = DFLT_HEADER
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(":")
        if not parts:
            continue
        if parts[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = parts
            continue
        row = {}
        for i, key in enumerate(header):
            row[key] = parts[i] if i < len(parts) else ""
        name = row.get("name", "")
        if name and name not in pools:
            pools[name] = row
    return pools, ""

def main(ctx, params):
    if params.get("_discover"):
        pools, err = _fetch_pools(ctx, params)
        if pools == None:
            return {"changed": False, "msg": "discovery failed: " + err,
                    "data": {"discovery": []}}
        out = []
        for name in sorted(pools.keys()):
            out.append({
                "item": name,
                "params": {"warn": 80.0, "crit": 90.0},
                "metrics": ["used_percent", "used_mb", "avail_mb", "total_mb", "fs_provisioning"],
            })
        return {"changed": False, "msg": "discovered %d pools" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    pools, err = _fetch_pools(ctx, params)
    if pools == None:
        return {"changed": False, "msg": "data unavailable: " + err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = pools.get(item)
    if data == None:
        return {"changed": False, "msg": "pool not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = data.get("status", "")
    if status != "online":
        return {"changed": False, "msg": "Status: " + status,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    capacity_mb = _to_mb(data.get("capacity", ""))
    real_mb = _to_mb(data.get("real_capacity", ""))
    virtual_mb = _to_mb(data.get("virtual_capacity", ""))

    if capacity_mb <= 0.0:
        return {"changed": False, "msg": "pool capacity is zero",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    avail_mb = capacity_mb - real_mb
    used_percent = 100.0 * real_mb / capacity_mb

    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")

    provisioning = 100.0 * virtual_mb / capacity_mb
    prov_state = "OK"
    prov_detail = ""
    prov_warn = params.get("provisioning_warn", None)
    prov_crit = params.get("provisioning_crit", None)
    if prov_warn != None and prov_crit != None:
        if provisioning >= prov_crit:
            prov_state = "CRIT"
        elif provisioning >= prov_warn:
            prov_state = "WARN"
        if prov_state != "OK":
            prov_detail = " (provisioning warn/crit at %f%%/%f%%)" % (prov_warn, prov_crit)

    final_state = state if STATE_ORDER.get(state, 0) >= STATE_ORDER.get(prov_state, 0) else prov_state

    msg = "Used: %f%% (%f of %f MB), Provisioning: %f%%%s" % (
        used_percent, real_mb, capacity_mb, provisioning, prov_detail,
    )
    metrics = {
        "used_percent": used_percent,
        "used_mb": real_mb,
        "avail_mb": avail_mb,
        "total_mb": capacity_mb,
        "fs_provisioning": virtual_mb * 1024.0 * 1024.0,
    }
    return {"changed": False, "msg": msg,
            "data": {"state": final_state, "metrics": metrics, "details": ""}}