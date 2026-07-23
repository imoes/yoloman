# UNIT_TO_MB[unit] = factor to multiply a value in that unit to get MB
UNIT_TO_MB = {
    "Bytes": 1.0 / 1048576.0,
    "KB": 1.0 / 1024.0,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1048576.0,
}

def _parse_sds_output(output):
    """Parse scli --query_all_sds text into {sds_id: {key: [tokens]}}."""
    section = {}
    sys_id = ""
    for line in output.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "SDS" and len(parts) >= 2:
            sys_id = parts[1].rstrip(":")
            if sys_id not in section:
                section[sys_id] = {}
        elif sys_id != "" and sys_id in section:
            section[sys_id][parts[0]] = parts[1:]
    return section

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["scli", "--query_all_sds"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "scli --query_all_sds failed: " + res.stderr,
                "data": {"discovery": []},
            }
        section = _parse_sds_output(res.stdout)
        items = []
        for sds_id in section:
            items.append({
                "item": sds_id,
                "params": {"warn": 80.0, "crit": 90.0},
                "metrics": ["used_percent", "used_mb", "free_mb", "total_mb"],
            })
        return {
            "changed": False,
            "msg": "discovered %d SDS items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = ctx.run(["scli", "--query_all_sds"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "scli --query_all_sds failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse_sds_output(res.stdout)
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "SDS not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    max_cap = data.get("MAX_CAPACITY_IN_KB")
    unused_cap = data.get("UNUSED_CAPACITY_IN_KB")
    if max_cap == None or unused_cap == None:
        return {
            "changed": False,
            "msg": "capacity fields missing for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Each capacity line parses to e.g. ["21.8", "TB", "(22353", "GB)"]
    # index 2 = parenthetical value with leading "(", index 3 = unit with trailing ")"
    if len(max_cap) < 4 or len(unused_cap) < 4:
        return {
            "changed": False,
            "msg": "unexpected capacity format for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    unit = max_cap[3].rstrip(")")
    if unit not in UNIT_TO_MB:
        return {
            "changed": False,
            "msg": "Unknown unit: " + unit,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total_str = max_cap[2].lstrip("(")
    free_str = unused_cap[2].lstrip("(")
    total_raw = int(total_str) if total_str.isdigit() else 0
    free_raw = int(free_str) if free_str.isdigit() else 0

    factor = UNIT_TO_MB[unit]
    total_mb = total_raw * factor
    free_mb = free_raw * factor

    if total_mb <= 0:
        return {
            "changed": False,
            "msg": "zero or invalid total capacity for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used_mb = total_mb - free_mb
    used_percent = (used_mb / total_mb) * 100.0

    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)

    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Used: %f%% (%f of %f MB)" % (used_percent, used_mb, total_mb)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "used_mb": used_mb,
                "free_mb": free_mb,
                "total_mb": total_mb,
            },
            "details": "",
        },
    }