def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)


def discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = ".1.3.6.1.4.1.12356.101.8.2.1.1"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed", "data": {"discovery": []}}
        return {"changed": False, "msg": "snmpwalk failed: " + res.stderr, "data": {"discovery": []}}

    found = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        if line_oid == oid or not line_oid.startswith(oid + "."):
            continue
        idx = line_oid[len(oid) + 1:]
        if idx == "":
            continue
        if idx not in found:
            found[idx] = {"detected": None, "blocked": None}

    rows = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        val = line[sp + 1:].strip()
        if not line_oid.startswith(oid + "."):
            continue
        suffix = line_oid[len(oid):]  # ".<idx>.<col>"
        dot1 = suffix.find(".")
        if dot1 <= 0:
            continue
        rest = suffix[dot1 + 1:]  # "<idx>.<col>"
        dot2 = rest.find(".")
        if dot2 <= 0 or dot2 == len(rest) - 1:
            continue
        idx = rest[:dot2]
        col = rest[dot2 + 1:]
        if idx not in found:
            found[idx] = {"detected": None, "blocked": None}
        colval = _to_int(val)
        if col == "1":
            found[idx]["detected"] = colval
        elif col == "2":
            found[idx]["blocked"] = colval

    items = {}
    for idx, vals in found.items():
        if vals["detected"] != None and vals["blocked"] != None:
            items[idx] = vals

    discovery = []
    for idx in sorted(items.keys()):
        discovery.append({
            "item": idx,
            "params": {"detections": (100.0, 300.0)},
            "metrics": ["fortigate_detection_rate", "fortigate_blocking_rate"],
        })
    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }


def check(ctx, params):
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.12356.101.8.2.1.1"

    det_oid = base + "." + item + ".1"
    blk_oid = base + "." + item + ".2"
    det_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, det_oid],
        mutates=False,
    )
    blk_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, blk_oid],
        mutates=False,
    )
    if det_res.rc != 0 or blk_res.rc != 0:
        return {
            "changed": False,
            "msg": "no antivirus data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    detected = _to_int(det_res.stdout.strip())
    blocked = _to_int(blk_res.stdout.strip())
    if detected == None or blocked == None:
        return {
            "changed": False,
            "msg": "could not parse antivirus counters for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    now = ctx.facts().get("_now", None)
    # Rate calculation is non-deterministic without persistent state, so we
    # report raw counters and grade detections against the threshold.
    levels = params.get("detections", (100.0, 300.0))
    warn = levels[0] if len(levels) > 0 else 100.0
    crit = levels[1] if len(levels) > 1 else 300.0

    state = _grade_upper(detected, warn, crit)
    msg = "Detection rate threshold: %s (detected=%d, blocked=%d)" % (state, detected, blocked)
    metrics = {"fortigate_detection_rate": float(detected), "fortigate_blocking_rate": float(blocked)}
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }


def _to_int(val):
    s = val.strip()
    if s.isdigit():
        return int(s)
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if s.isdigit():
        return -int(s)
    return None


def _grade_upper(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"