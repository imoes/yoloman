def _bwc_iops(bwc):
    secs = bwc.get("numSeconds", 0)
    if secs == 0:
        return 0.0
    return float(bwc.get("numOccured", 0)) / float(secs)

def _bwc_throughput_bytes(bwc):
    secs = bwc.get("numSeconds", 0)
    if secs == 0:
        return 0.0
    return float(bwc.get("totalWeightInKb", 0)) * 1024.0 / float(secs)

def _fmt_rate(bps):
    if bps >= 1073741824.0:
        return "%f GB/s" % (bps / 1073741824.0)
    if bps >= 1048576.0:
        return "%f MB/s" % (bps / 1048576.0)
    if bps >= 1024.0:
        return "%f KB/s" % (bps / 1024.0)
    return "%f B/s" % bps

def _api_login(ctx, host, username, password):
    res = ctx.run(
        ["curl", "-sk", "-u", username + ":" + password, "https://" + host + "/api/login"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    token = res.stdout.strip().strip('"')
    if not token:
        return None
    return token

def _api_get(ctx, host, username, token, path):
    res = ctx.run(
        ["curl", "-sk", "-u", username + ":" + token, "https://" + host + path],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    return json.decode(res.stdout)

def _apply_level(val, warn, crit):
    if crit != None and val >= crit:
        return "CRIT"
    if warn != None and val >= warn:
        return "WARN"
    return "OK"

STATE_ORDER = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}

def _worse(a, b):
    if STATE_ORDER.get(a, 0) >= STATE_ORDER.get(b, 0):
        return a
    return b

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "admin")
    password = params.get("password", "")

    token = _api_login(ctx, host, username, password)
    if token == None:
        return {
            "changed": False,
            "msg": "ScaleIO MDM login failed for " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        pools = _api_get(ctx, host, username, token, "/api/types/StoragePool/instances")
        if pools == None or type(pools) != "list":
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        items = []
        for pool in pools:
            pid = pool.get("id", "")
            if pid:
                items.append({
                    "item": pid,
                    "params": {},
                    "metrics": ["read_ios", "write_ios", "read_throughput", "write_throughput"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    pool_info = _api_get(ctx, host, username, token, "/api/instances/StoragePool::" + item)
    pool_name = item
    if pool_info != None and type(pool_info) == "dict":
        pool_name = pool_info.get("name", item)

    stats = _api_get(
        ctx, host, username, token,
        "/api/instances/StoragePool::" + item + "/relationships/Statistics",
    )
    if stats == None or type(stats) != "dict":
        return {
            "changed": False,
            "msg": "no stats for pool " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    pri_r = stats.get("primaryReadBwc", {})
    pri_w = stats.get("primaryWriteBwc", {})
    sec_r = stats.get("secondaryReadBwc", {})
    sec_w = stats.get("secondaryWriteBwc", {})

    read_ios = _bwc_iops(pri_r) + _bwc_iops(sec_r)
    write_ios = _bwc_iops(pri_w) + _bwc_iops(sec_w)
    read_tp = _bwc_throughput_bytes(pri_r) + _bwc_throughput_bytes(sec_r)
    write_tp = _bwc_throughput_bytes(pri_w) + _bwc_throughput_bytes(sec_w)

    r_ios_warn = params.get("read_ios_warn", None)
    r_ios_crit = params.get("read_ios_crit", None)
    w_ios_warn = params.get("write_ios_warn", None)
    w_ios_crit = params.get("write_ios_crit", None)
    r_tp_warn = params.get("read_throughput_warn", None)
    r_tp_crit = params.get("read_throughput_crit", None)
    w_tp_warn = params.get("write_throughput_warn", None)
    w_tp_crit = params.get("write_throughput_crit", None)

    state = "OK"
    state = _worse(state, _apply_level(read_ios, r_ios_warn, r_ios_crit))
    state = _worse(state, _apply_level(write_ios, w_ios_warn, w_ios_crit))
    state = _worse(state, _apply_level(read_tp, r_tp_warn, r_tp_crit))
    state = _worse(state, _apply_level(write_tp, w_tp_warn, w_tp_crit))

    msg = "Name: %s, Read: %f IOPS %s, Write: %f IOPS %s" % (
        pool_name, read_ios, _fmt_rate(read_tp), write_ios, _fmt_rate(write_tp),
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "read_ios": read_ios,
                "write_ios": write_ios,
                "read_throughput": read_tp,
                "write_throughput": write_tp,
            },
            "details": "",
        },
    }