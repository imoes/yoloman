UNIT_TO_MB = {
    "Bytes": 1.0 / 1048576.0,
    "KB": 1.0 / 1024.0,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1048576.0,
}

def _capacity_mb(tokens):
    if len(tokens) < 2:
        return None
    unit = tokens[1].rstrip(")")
    factor = UNIT_TO_MB.get(unit)
    if factor == None:
        return None
    val_s = tokens[0].lstrip("(")
    if not val_s.replace(".", "").isdigit():
        return None
    return float(val_s) * factor

def _parse_pools(stdout):
    pools = {}
    cur_id = None
    cur = {}
    for raw in stdout.splitlines():
        line = raw.strip()
        if not line:
            continue
        lo = line.lower()
        if "storage pool id" in lo:
            if cur_id != None:
                pools[cur_id] = cur
            colon_pos = line.find(":")
            if colon_pos >= 0:
                pool_id = line[colon_pos + 1:].strip().rstrip(":")
                if not pool_id:
                    words = line.split()
                    pool_id = words[-1].rstrip(":")
            else:
                words = line.split()
                pool_id = words[-1].rstrip(":")
            cur_id = pool_id
            cur = {"id": cur_id, "name": "", "max_mb": 0.0, "free_mb": 0.0, "failed": 0.0}
        elif cur_id != None:
            if lo.startswith("name:"):
                cur["name"] = line.split(":", 1)[1].strip()
            elif ("maximum capacity" in lo or "max capacity" in lo) and ":" in line:
                rest = line.split(":", 1)[1].strip().split()
                mb = _capacity_mb(rest)
                if mb != None:
                    cur["max_mb"] = mb
            elif "failed capacity" in lo and ":" in line:
                rest = line.split(":", 1)[1].strip().split()
                if len(rest) >= 1 and rest[0].replace(".", "").isdigit():
                    cur["failed"] = float(rest[0])
            elif ("unused capacity" in lo or "available capacity" in lo or "free capacity" in lo) and "failed" not in lo and ":" in line:
                rest = line.split(":", 1)[1].strip().split()
                mb = _capacity_mb(rest)
                if mb != None:
                    cur["free_mb"] = mb
    if cur_id != None:
        pools[cur_id] = cur
    return pools

def main(ctx, params):
    host = params.get("host", "")
    if host:
        cmd = ["scli", "--mdm_ip", host, "--query_all_storage_pools", "--approve_certificate"]
    else:
        cmd = ["scli", "--query_all_storage_pools", "--approve_certificate"]

    res = ctx.run(cmd, mutates=False, ok_codes=[0, 1, 2, 127])
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "scli failed (rc=%d): %s" % (res.rc, res.stderr.strip()),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    pools = _parse_pools(res.stdout)

    if params.get("_discover"):
        discovery = []
        for pool_id in pools:
            discovery.append({
                "item": pool_id,
                "params": {"levels": [80.0, 90.0]},
                "metrics": ["used_percent", "used_mb", "total_mb", "free_mb", "failed_bytes"],
            })
        return {
            "changed": False,
            "msg": "discovered %d storage pools" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    pool = pools.get(item)
    if pool == None:
        return {
            "changed": False,
            "msg": "storage pool not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total_mb = pool["max_mb"]
    free_mb = pool["free_mb"]
    failed = pool["failed"]

    if total_mb <= 0.0:
        return {
            "changed": False,
            "msg": "no capacity data for pool %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used_mb = total_mb - free_mb
    used_pct = used_mb / total_mb * 100.0

    levels = params.get("levels", [80.0, 90.0])
    warn = levels[0]
    crit = levels[1]

    state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")
    if failed > 0.0:
        state = "CRIT"

    name = pool.get("name", item)
    if not name:
        name = item
    total_gb = total_mb / 1024.0
    used_gb = used_mb / 1024.0
    free_gb = free_mb / 1024.0

    msg = "Pool %s: %f%% used (%f of %f GB, free %f GB)" % (
        name, used_pct, used_gb, total_gb, free_gb
    )
    if failed > 0.0:
        msg = msg + ", Failed: %d Bytes" % int(failed)

    details = ""
    if state != "OK":
        details = "WARN at %f%%, CRIT at %f%%" % (warn, crit)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_pct,
                "used_mb": used_mb,
                "total_mb": total_mb,
                "free_mb": free_mb,
                "failed_bytes": failed,
            },
            "details": details,
        },
    }