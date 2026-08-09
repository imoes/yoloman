# ScaleIO SP rebalance IO %s — read-only Starlark check module

KNOWN_CONVERSION_VALUES_INTO_MB = {
    "Bytes": 1.0 / 1024.0 / 1024.0,
    "KB":    1.0 / 1024.0,
    "MB":    1.0,
    "GB":    1024.0,
    "TB":    1024.0 * 1024.0,
}

KNOWN_CONVERSION_VALUES_INTO_BYTES = {
    "Bytes": 1.0,
    "KB":    1024.0,
    "MB":    1024.0 * 1024.0,
    "GB":    1024.0 * 1024.0 * 1024.0,
    "TB":    1024.0 * 1024.0 * 1024.0 * 1024.0,
}

def _is_digit(s):
    s = s.strip()
    if s == "":
        return False
    neg = False
    if s[0] == "-":
        neg = True
        s = s[1:]
    if s == "":
        return False
    return s.isdigit()

def _is_float(s):
    s = s.strip()
    if s == "":
        return False
    neg = False
    if s[0] == "-":
        neg = True
        s = s[1:]
    parts = s.split(".")
    if len(parts) == 1:
        return _is_digit(s)
    if len(parts) != 2:
        return False
    if parts[0] == "":
        left_ok = True
    else:
        left_ok = parts[0].isdigit()
    if parts[1] == "":
        right_ok = True
    else:
        right_ok = parts[1].isdigit()
    return left_ok and right_ok

def _to_float(value):
    if value == None:
        return None
    s = str(value).strip()
    if s == "":
        return None
    cleaned = s.replace(",", "")
    if not _is_float(cleaned):
        return None
    return float(cleaned)

def _split_bwc(token):
    if token == None:
        return None
    parts = token.strip().split()
    if len(parts) < 4:
        return None
    if not _is_float(parts[0]) or not _is_float(parts[2]):
        return None
    return (float(parts[0]), float(parts[2]), parts[3])

def _make_disk_rw(read_data, write_data):
    if read_data == None or write_data == None:
        return None
    read_unit = read_data[2]
    write_unit = write_data[2]
    if read_unit not in KNOWN_CONVERSION_VALUES_INTO_BYTES:
        return {"error": "Unknown unit: " + read_unit}
    if write_unit not in KNOWN_CONVERSION_VALUES_INTO_BYTES:
        return {"error": "Unknown unit: " + write_unit}
    return {
        "read_operations":  read_data[0],
        "read_throughput":  read_data[1] * KNOWN_CONVERSION_VALUES_INTO_BYTES[read_unit],
        "write_operations": write_data[0],
        "write_throughput": write_data[1] * KNOWN_CONVERSION_VALUES_INTO_BYTES[write_unit],
    }

def _fmt_bytes(n):
    if n == None:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    val = float(n)
    idx = 0
    while val >= 1024.0 and idx < len(units) - 1:
        val = val / 1024.0
        idx = idx + 1
    if idx == 0:
        return "%d %s" % (int(val), units[idx])
    return "%f %s" % (val, units[idx])

def _grade_levels(value, params):
    warn = params.get("warn")
    crit = params.get("crit")
    if warn == None and params.get("levels") != None:
        lvls = params.get("levels")
        if type(lvls) == "list" and len(lvls) >= 2:
            warn = lvls[0]
            crit = lvls[1]
        elif hasattr(lvls, "get"):
            warn = lvls.get("warn")
            crit = lvls.get("crit")
    if warn == None and crit == None:
        return "OK"
    if value == None:
        return "OK"
    v = float(value)
    if crit != None and v >= float(crit):
        return "CRIT"
    if warn != None and v >= float(warn):
        return "WARN"
    return "OK"

def _parse_scli_capacity(token):
    if token == None:
        return None
    t = token.strip()
    if t == "":
        return None
    before = t
    p = t.find("(")
    if p >= 0:
        before = t[:p].strip()
    parts = before.split()
    if len(parts) < 2:
        return None
    if not _is_float(parts[0]):
        return None
    return (float(parts[0]), parts[1])

def _capacity_to_mb(token):
    parsed = _parse_scli_capacity(token)
    if parsed == None:
        return None
    val, unit = parsed
    if unit not in KNOWN_CONVERSION_VALUES_INTO_MB:
        return None
    return val * KNOWN_CONVERSION_VALUES_INTO_MB[unit]

def _fetch_storage_pools(ctx):
    res = ctx.run(["scli", "--query_all_pools"], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout

def _discover(ctx):
    res = ctx.run(["scli", "--version"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "scli not installed",
                "data": {"discovery": []}}
    if res.rc != 0:
        return {"changed": False, "msg": "scli not available",
                "data": {"discovery": []}}
    out = _fetch_storage_pools(ctx)
    if out == None:
        return {"changed": False, "msg": "no ScaleIO pools found",
                "data": {"discovery": []}}
    pools = []
    for line in out.splitlines():
        line = line.strip()
        if line == "" or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 1:
            continue
        pool_id = parts[0]
        pools.append({
            "item": pool_id,
            "params": {"warn": 80, "crit": 90},
            "metrics": ["read_ios", "read_throughput", "write_ios", "write_throughput"],
        })
    return {"changed": False,
            "msg": "discovered %d items" % len(pools),
            "data": {"discovery": pools}}

def _fetch_pool_detail(ctx, item):
    res = ctx.run(["scli", "--query_pool_id", item], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout

def _parse_pool_detail(out):
    if out == None:
        return None
    pool = {}
    pool["NAME"] = ""
    pool["MAX_CAPACITY_IN_KB"] = ""
    pool["UNUSED_CAPACITY_IN_KB"] = ""
    pool["FAILED_CAPACITY_IN_KB"] = ""
    pool["TOTAL_READ_BWC"] = ""
    pool["TOTAL_WRITE_BWC"] = ""
    pool["REBALANCE_READ_BWC"] = ""
    pool["REBALANCE_WRITE_BWC"] = ""
    current_key = None
    for raw in out.splitlines():
        line = raw.strip()
        if line == "":
            continue
        if line.endswith(":"):
            current_key = line[:-1].strip()
            continue
        if current_key == None:
            continue
        field = line.split(":", 1)
        if len(field) == 2:
            pool[field[0].strip()] = field[1].strip()
        elif ":" not in line:
            if pool[current_key] == "":
                pool[current_key] = line
            else:
                pool[current_key] = pool[current_key] + " " + line
    return pool

def _check(ctx, item, params):
    out = _fetch_pool_detail(ctx, item)
    if out == None:
        return {"changed": False,
                "msg": "no ScaleIO pool with id " + item + " found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pool = _parse_pool_detail(out)
    if pool == None:
        return {"changed": False,
                "msg": "failed to parse ScaleIO pool " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name = pool.get("NAME", "")
    rebalance_rw = _make_disk_rw(
        _split_bwc(pool.get("REBALANCE_READ_BWC", "")),
        _split_bwc(pool.get("REBALANCE_WRITE_BWC", "")),
    )

    summary_parts = []
    metrics = {}
    details_lines = []

    if name != "":
        summary_parts.append("Name: " + name)

    if rebalance_rw == None:
        return {"changed": False,
                "msg": "Unknown unit for rebalance IO",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if rebalance_rw.get("error") != None:
        return {"changed": False,
                "msg": rebalance_rw["error"],
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics["read_ios"] = rebalance_rw["read_operations"]
    metrics["read_throughput"] = rebalance_rw["read_throughput"]
    metrics["write_ios"] = rebalance_rw["write_operations"]
    metrics["write_throughput"] = rebalance_rw["write_throughput"]

    summary_parts.append("Read: %d IOPS %s/s" % (
        int(metrics["read_ios"]),
        _fmt_bytes(metrics["read_throughput"]),
    ))
    summary_parts.append("Write: %d IOPS %s/s" % (
        int(metrics["write_ios"]),
        _fmt_bytes(metrics["write_throughput"]),
    ))

    details_lines.append("Pool: " + name)
    details_lines.append("Rebalance Read IOs: %d" % int(metrics["read_ios"]))
    details_lines.append("Rebalance Write IOs: %d" % int(metrics["write_ios"]))
    details_lines.append("Rebalance Read throughput: " + _fmt_bytes(metrics["read_throughput"]) + "/s")
    details_lines.append("Rebalance Write throughput: " + _fmt_bytes(metrics["write_throughput"]) + "/s")

    failed_mb = _capacity_to_mb(pool.get("FAILED_CAPACITY_IN_KB", ""))
    if failed_mb != None and failed_mb > 0:
        details_lines.append("Failed Capacity: " + _fmt_bytes(failed_mb * 1024.0 * 1024.0))

    state = "OK"
    r_state = _grade_levels(metrics["read_throughput"], params)
    w_state = _grade_levels(metrics["write_throughput"], params)
    for s in [r_state, w_state]:
        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN" and state != "CRIT":
            state = "WARN"

    if failed_mb != None and failed_mb > 0:
        state = "CRIT"

    return {"changed": False,
            "msg": ", ".join(summary_parts),
            "data": {"state": state, "metrics": metrics, "details": "\n".join(details_lines)}}

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx)
    item = params.get("item", "")
    if item == "":
        return {"changed": False,
                "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return _check(ctx, item, params)