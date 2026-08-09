def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        # Attempt unauthenticated HTTP first, then with basic auth
        res = ctx.run([
            "curl", "-s", "-f", "http://localhost:8091/pools/default/buckets"
        ], mutates=False)
        if res.rc != 0:
            user = params.get("user", "Administrator")
            password = params.get("pass", "")
            if password != "":
                res = ctx.run([
                    "curl", "-s", "-f", "http://localhost:8091/pools/default/buckets",
                    "-u", user + ":" + password
                ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "could not fetch buckets (HTTP error or no data)",
                "data": {"discovery": []}
            }
        # Guard before decode
        if not res.stdout:
            return {
                "changed": False,
                "msg": "empty response from buckets endpoint",
                "data": {"discovery": []}
            }
        buckets = json.decode(res.stdout)
        out = []
        for bucket in buckets:
            name = bucket.get("name")
            if not name:
                continue
            ram = bucket.get("ram", {})
            if ram.get("mem_total") != None and ram.get("mem_free") != None:
                out.append({
                    "item": name,
                    "params": {"levels": None},
                    "metrics": ["memused_couchbase_bucket", "mem_low_wat", "mem_high_wat"]
                })
        return {
            "changed": False,
            "msg": "discovered %d buckets" % len(out),
            "data": {"discovery": out}
        }

    # ===== CHECK MODE =====
    item = params.get("item", "")
    # Fetch buckets again for the item-specific check
    res = ctx.run([
        "curl", "-s", "-f", "http://localhost:8091/pools/default/buckets"
    ], mutates=False)
    if res.rc != 0:
        user = params.get("user", "Administrator")
        password = params.get("pass", "")
        if password != "":
            res = ctx.run([
                "curl", "-s", "-f", "http://localhost:8091/pools/default/buckets",
                "-u", user + ":" + password
            ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "could not fetch buckets data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    # Guard before decode
    if not res.stdout:
        return {
            "changed": False,
            "msg": "empty response from buckets endpoint",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    buckets = json.decode(res.stdout)

    # Find the requested bucket
    bucket_data = None
    for b in buckets:
        if b.get("name") == item:
            bucket_data = b
            break

    if not bucket_data:
        return {
            "changed": False,
            "msg": "bucket not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Extract memory data
    ram = bucket_data.get("ram", {})
    mem_total = ram.get("mem_total")
    mem_free = ram.get("mem_free")
    mem_used = None
    if mem_total != None and mem_free != None:
        mem_used = mem_total - mem_free

    # Determine mode: "abs_used" if levels[0] is int, else "perc_used"
    levels = params.get("levels")
    mode = "perc_used"
    if levels != None and type(levels) == "list" and len(levels) >= 2 and type(levels[0]) == "int":
        mode = "abs_used"

    state = "OK"
    details = []
    metrics = {}

    # Compute usage percentage if possible
    usage_pct = None
    if mem_total != None and mem_used != None and mem_total > 0:
        usage_pct = float(mem_used) / float(mem_total) * 100.0

    # Apply thresholds for usage
    warn_pct = None
    crit_pct = None
    if mode == "perc_used":
        if levels != None and type(levels) == "list" and len(levels) >= 2:
            warn_pct = levels[0] if levels[0] != None else None
            crit_pct = levels[1] if levels[1] != None else None
        # Default levels for memory_multiitem: (80, 90) for percentages
        if warn_pct == None:
            warn_pct = 80.0
        if crit_pct == None:
            crit_pct = 90.0

        if usage_pct != None:
            if crit_pct != None and usage_pct >= crit_pct:
                state = "CRIT"
            elif warn_pct != None and usage_pct >= warn_pct:
                state = "WARN"
            metrics["memused_couchbase_bucket"] = usage_pct
            details.append("Usage: %f%%" % usage_pct)
    else:  # abs_used
        warn_abs = None
        crit_abs = None
        if levels != None and type(levels) == "list" and len(levels) >= 2:
            warn_abs = levels[0] if levels[0] != None else None
            crit_abs = levels[1] if levels[1] != None else None
        # Default levels for memory_multiitem: 1 GiB, 2 GiB
        if warn_abs == None:
            warn_abs = 1073741824.0
        if crit_abs == None:
            crit_abs = 2147483648.0

        if mem_used != None:
            if crit_abs != None and mem_used >= crit_abs:
                state = "CRIT"
            elif warn_abs != None and mem_used >= warn_abs:
                state = "WARN"
            metrics["memused_couchbase_bucket"] = mem_used
            details.append("Usage: %d bytes" % mem_used)

    # Low watermark (ep_mem_low_wat) — bytes
    low_watermark = bucket_data.get("ep_mem_low_wat")
    if low_watermark != None:
        metrics["mem_low_wat"] = low_watermark

    # High watermark (ep_mem_high_wat) — bytes
    high_watermark = bucket_data.get("ep_mem_high_wat")
    if high_watermark != None:
        metrics["mem_high_wat"] = high_watermark

    # Format message
    if usage_pct != None:
        msg = "%s usage: %f%%" % (item, usage_pct)
    elif mem_used != None:
        msg = "%s usage: %d bytes" % (item, mem_used)
    else:
        msg = "%s memory data incomplete" % item

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ", ".join(details)
        }
    }
