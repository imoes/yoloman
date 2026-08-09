def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/spl/kstat/zfs/arcstats"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "not installed", "data": {"discovery": []}}
        parsed = {}
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[1] == "0":
                key = parts[0]
                val = parts[2]
                if val.isdigit():
                    parsed[key] = int(val)
        if parsed.get("l2_size", 0) > 0:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {}, "metrics": ["l2_hit_ratio", "l2_size"]}
                    ]}}
        return {"changed": False, "msg": "no L2 cache", "data": {"discovery": []}}
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/spl/kstat/zfs/arcstats"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "arcstats not readable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "0":
            key = parts[0]
            val = parts[2]
            if val.isdigit():
                parsed[key] = int(val)
    metrics = {}
    details = ""
    state = "OK"
    if "l2_hits" in parsed and "l2_misses" in parsed:
        total = parsed["l2_hits"] + parsed["l2_misses"]
        if total > 0:
            ratio = float(parsed["l2_hits"]) / total * 100
            metrics["l2_hit_ratio"] = ratio
            details = "L2 hit ratio: %f%%" % ratio
        else:
            state = "UNKNOWN"
            details = "No info about L2 hit ratio available"
    else:
        state = "UNKNOWN"
        details = "No info about L2 hit ratio available"
    if "l2_size" in parsed:
        metrics["l2_size"] = float(parsed["l2_size"])
        if details:
            details = details + ", L2 size: %d bytes" % parsed["l2_size"]
        else:
            details = "L2 size: %d bytes" % parsed["l2_size"]
    else:
        if not details:
            state = "UNKNOWN"
            details = "No info about L2 size available"
    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details}}