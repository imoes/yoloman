def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.11096.6.1.1.6.4.2.1"
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-Of", host, base],
            mutates=False,
        )
        if res.rc == 127:
            return {
                "changed": False,
                "msg": "snmpwalk not installed",
                "data": {"discovery": []},
            }
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed: " + res.stderr,
                "data": {"discovery": []},
            }
        rows = {}
        for line in res.stdout.splitlines():
            sp = line.split()
            if len(sp) < 2:
                continue
            oid = sp[0]
            val = " ".join(sp[1:])
            suffix = oid[len(base) + 1:]
            parts = suffix.split(".")
            if len(parts) < 2:
                continue
            idx = parts[0]
            col = parts[1]
            if idx not in rows:
                rows[idx] = {}
            rows[idx][col] = val
        out = []
        for idx in rows:
            r = rows[idx]
            span_id = r.get("1", "")
            label = r.get("2", "")
            if not span_id:
                continue
            item = span_id + " " + label
            out.append({
                "item": item,
                "params": {"warn": 80, "crit": 90},
                "metrics": ["size", "used_percent", "size_avail"],
            })
        out = sorted(out, key=lambda e: e["item"])
        return {
            "changed": False,
            "msg": "discovered %d spans" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.11096.6.1.1.6.4.2.1"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-Of", host, base],
        mutates=False,
    )
    if res.rc == 127:
        return {
            "changed": False,
            "msg": "snmpwalk not installed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed: " + res.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    rows = {}
    for line in res.stdout.splitlines():
        sp = line.split()
        if len(sp) < 2:
            continue
        oid = sp[0]
        val = " ".join(sp[1:])
        suffix = oid[len(base) + 1:]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        idx = parts[0]
        col = parts[1]
        if idx not in rows:
            rows[idx] = {}
        rows[idx][col] = val

    found_idx = None
    for idx in rows:
        r = rows[idx]
        span_id = r.get("1", "")
        label = r.get("2", "")
        cand = span_id + " " + label
        if cand == item:
            found_idx = idx
            break

    if found_idx == None:
        return {
            "changed": False,
            "msg": "no such span: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    r = rows[found_idx]
    total_upper = int(r.get("3", "0"))
    total_lower = int(r.get("4", "0"))
    used_upper = int(r.get("5", "0"))
    used_lower = int(r.get("6", "0"))
    size_mb = (total_upper * 4294967296 + total_lower) / (1024.0 * 1024.0)
    used_mb = (used_upper * 4294967296 + used_lower) / (1024.0 * 1024.0)
    avail_mb = size_mb - used_mb
    used_percent = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Size: %f MB, Used: %f MB (%f%%)" % (size_mb, used_mb, used_percent),
        "data": {
            "state": state,
            "metrics": {
                "size": size_mb,
                "size_avail": avail_mb,
                "used_percent": used_percent,
            },
            "details": "",
        },
    }