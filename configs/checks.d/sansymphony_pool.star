_DEFAULT_LEVELS = (80.0, 90.0)

_STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2}

def _worse_state(a, b):
    ra = _STATE_RANK.get(a, 1)
    rb = _STATE_RANK.get(b, 1)
    if ra >= rb:
        return a
    return b

def _format_bytes(b):
    if b >= 1073741824:
        return "%f GB" % (b / 1073741824.0)
    if b >= 1048576:
        return "%f MB" % (b / 1048576.0)
    if b >= 1024:
        return "%f KB" % (b / 1024.0)
    return "%d B" % b

def _parse_int(s):
    s = s.strip()
    if s.isdigit():
        return int(s)
    return 0

def _get_pools(ctx):
    ps_script = (
        "Add-PSSnapin DataCore.Executive.PSSnapIn -ErrorAction SilentlyContinue; " +
        "$pools = Get-DcPool; " +
        "foreach ($p in $pools) { " +
        "  Write-Output ($p.Caption + [char]9 + $p.Status + [char]9 + $p.CacheState + [char]9 + $p.PoolType + [char]9 + $p.AllocatedBytes + [char]9 + $p.AvailableBytes + [char]9 + $p.TotalBytes) " +
        "}"
    )
    res = ctx.run(
        ["powershell", "-NonInteractive", "-NoProfile", "-Command", ps_script],
        mutates=False,
        ok_codes=[0, 1],
    )
    pools = {}
    if not res.stdout:
        return pools
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        name = parts[0]
        pools[name] = {
            "name": name,
            "status": parts[1],
            "cache_mode": parts[2],
            "pool_type": parts[3],
            "allocated": _parse_int(parts[4]),
            "available": _parse_int(parts[5]),
            "total": _parse_int(parts[6]),
        }
    return pools

def main(ctx, params):
    if params.get("_discover"):
        pools = _get_pools(ctx)
        discovery = []
        for name in pools:
            discovery.append({
                "item": name,
                "params": {"levels": _DEFAULT_LEVELS},
                "metrics": ["pool_allocation", "fs_used", "fs_free", "fs_used_percent"],
            })
        return {
            "changed": False,
            "msg": "discovered %d pools" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    pools = _get_pools(ctx)
    pool = pools.get(item)
    if pool == None:
        return {
            "changed": False,
            "msg": "pool not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = pool["status"]
    cache_mode = pool["cache_mode"]
    pool_type = pool["pool_type"]
    name = pool["name"]

    if status == "Running" and cache_mode == "ReadWrite":
        status_state = "OK"
    elif status == "Running":
        status_state = "WARN"
    else:
        status_state = "CRIT"

    base_msg = "%s pool %s is %s, its cache is in %s mode" % (pool_type, name, status, cache_mode)

    total = pool["total"]
    allocated = pool["allocated"]
    available = pool["available"]
    metrics = {}
    usage_state = "OK"
    usage_msg = ""

    if total > 0:
        percent_used = allocated * 100.0 / total
        metrics["pool_allocation"] = percent_used
        metrics["fs_used"] = allocated / 1048576.0
        metrics["fs_free"] = available / 1048576.0
        metrics["fs_used_percent"] = percent_used

        levels = params.get("levels", _DEFAULT_LEVELS)
        warn = levels[0]
        crit = levels[1]

        if percent_used >= crit:
            usage_state = "CRIT"
        elif percent_used >= warn:
            usage_state = "WARN"

        usage_msg = " - Used: %f%% (%s of %s)" % (
            percent_used,
            _format_bytes(allocated),
            _format_bytes(total),
        )

    final_state = _worse_state(status_state, usage_state)

    return {
        "changed": False,
        "msg": base_msg + usage_msg,
        "data": {"state": final_state, "metrics": metrics, "details": ""},
    }