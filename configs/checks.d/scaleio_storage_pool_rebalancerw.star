BYTES_CONVERSION = {
    "Bytes": 1.0,
    "KB": 1024.0,
    "MB": 1048576.0,
    "GB": 1073741824.0,
    "TB": 1099511627776.0,
}

STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _to_float(s):
    start = 1 if s.startswith("-") else 0
    core = s[start:]
    parts = core.split(".")
    if len(parts) > 2:
        return 0.0
    for p in parts:
        if len(p) == 0 or not p.isdigit():
            return 0.0
    return float(s)

def _parse_pools(stdout):
    pools = {}
    current_id = ""
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) < 2:
            continue
        if parts[0] == "STORAGE_POOL":
            current_id = parts[1].rstrip(":")
            pools[current_id] = {}
        elif current_id != "" and current_id in pools:
            pools[current_id][parts[0]] = parts[1:]
    return pools

def _parse_bwc(values):
    # Format: [ops, "IOPS", throughput, unit, "per-second"]
    if len(values) < 4:
        return None
    unit = values[3]
    if unit not in BYTES_CONVERSION:
        return None
    ops = _to_float(values[0])
    throughput = _to_float(values[2])
    return {"ops": ops, "throughput_bytes": throughput * BYTES_CONVERSION[unit]}

def _max_state(s1, s2):
    if STATE_RANK.get(s2, 0) > STATE_RANK.get(s1, 0):
        return s2
    return s1

def _check_level(state, value, levels):
    if levels == None:
        return state
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return _max_state(state, "CRIT")
    if value >= warn:
        return _max_state(state, "WARN")
    return state

def main(ctx, params):
    mdm_ip = params.get("mdm_ip", "")
    if mdm_ip != "":
        argv = ["scli", "--mdm_ip", mdm_ip, "--query_all_storage_pools", "--approve_certificate"]
    else:
        argv = ["scli", "--query_all_storage_pools", "--approve_certificate"]

    res = ctx.run(argv, mutates=False)

    if params.get("_discover"):
        if res.rc != 0:
            return {"changed": False, "msg": "scli failed: " + res.stderr,
                    "data": {"discovery": []}}
        pools = _parse_pools(res.stdout)
        items = []
        for pool_id in pools:
            items.append({
                "item": pool_id,
                "params": {},
                "metrics": ["rebalance_read_ios", "rebalance_read_throughput",
                            "rebalance_write_ios", "rebalance_write_throughput"],
            })
        return {"changed": False, "msg": "discovered %d storage pools" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")

    if res.rc != 0:
        return {"changed": False, "msg": "scli failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    pools = _parse_pools(res.stdout)
    pool = pools.get(item)
    if pool == None:
        return {"changed": False, "msg": "storage pool not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name_vals = pool.get("NAME")
    pool_name = name_vals[0] if name_vals != None else item

    read_vals = pool.get("REBALANCE_READ_BWC")
    write_vals = pool.get("REBALANCE_WRITE_BWC")

    if read_vals == None or write_vals == None:
        return {"changed": False, "msg": "missing REBALANCE_*_BWC fields for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    read_stats = _parse_bwc(read_vals)
    write_stats = _parse_bwc(write_vals)

    if read_stats == None:
        return {"changed": False, "msg": "unknown unit in REBALANCE_READ_BWC for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if write_stats == None:
        return {"changed": False, "msg": "unknown unit in REBALANCE_WRITE_BWC for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    r_ios = read_stats["ops"]
    r_tp = read_stats["throughput_bytes"]
    w_ios = write_stats["ops"]
    w_tp = write_stats["throughput_bytes"]

    state = "OK"
    state = _check_level(state, r_ios, params.get("read_ios"))
    state = _check_level(state, w_ios, params.get("write_ios"))
    state = _check_level(state, r_tp, params.get("read_throughput"))
    state = _check_level(state, w_tp, params.get("write_throughput"))

    msg = "Name: %s, Rebalance read: %f IOPS %f B/s, write: %f IOPS %f B/s" % (
        pool_name, r_ios, r_tp, w_ios, w_tp)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "rebalance_read_ios": r_ios,
                "rebalance_read_throughput": r_tp,
                "rebalance_write_ios": w_ios,
                "rebalance_write_throughput": w_tp,
            },
            "details": "",
        },
    }