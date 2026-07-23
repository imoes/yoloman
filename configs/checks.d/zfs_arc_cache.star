def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists("/proc/spl/kstat/zfs/arcstats"):
            return {"changed": False, "msg": "discovered 0 items (no arcstats file)",
                    "data": {"discovery": []}}

        content = ctx.file_read("/proc/spl/kstat/zfs/arcstats") if ctx.file_exists("/proc/spl/kstat/zfs/arcstats") else ""

        lines = content.split("\n")
        section = {}
        for line in lines:
            parts = line.strip().split()
            if len(parts) >= 3 and parts[1].isdigit():
                section[parts[0]] = int(parts[2])

        if section.get("hits") != None and section.get("misses") != None:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                        "hit_ratio", "prefetch_data_hit_ratio", "prefetch_metadata_hit_ratio",
                        "size", "arc_meta_used", "arc_meta_limit", "arc_meta_max",
                        "l2_hit_ratio", "l2_size"
                    ]}]}}
        return {"changed": False, "msg": "discovered 0 items (no hits/misses)",
                "data": {"discovery": []}}

    # Normal check mode (item is always "" for this check)
    if not ctx.file_exists("/proc/spl/kstat/zfs/arcstats"):
        return {"changed": False, "msg": "cannot read arcstats",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read("/proc/spl/kstat/zfs/arcstats")
    section = {}
    for line in content.split("\n"):
        parts = line.strip().split()
        if len(parts) >= 3 and parts[1].isdigit():
            section[parts[0]] = int(parts[2])

    def format_bytes(b):
        units = ["B", "KB", "MB", "GB", "TB", "PB"]
        i = 0
        val = float(b)
        while val >= 1024.0 and i < len(units)-1:
            val /= 1024.0
            i += 1
        return "%f %s" % (val, units[i])

    def add_hit_ratio(key_prefix):
        hits = section.get(key_prefix + "hits")
        misses = section.get(key_prefix + "misses")
        if hits != None and misses != None:
            total = hits + misses
            if total > 0:
                ratio = float(hits) / total * 100.0
                name = key_prefix.strip("_").replace("_", " ").title()
                name = name.replace(" ", "") + " Hit Ratio" if key_prefix else "Hit Ratio"
                return {"summary": "%s: %f%%" % (name, ratio), "metric_name": key_prefix + "hit_ratio", "value": ratio}
        return None

    summaries = []
    metrics = {}
    details_lines = []

    for key_prefix in ["", "prefetch_data_", "prefetch_metadata_"]:
        r = add_hit_ratio(key_prefix)
        if r:
            summaries.append(r["summary"])
            metrics[r["metric_name"]] = r["value"]

    if "size" in section:
        size_bytes = section["size"]
        size_human = format_bytes(float(size_bytes))
        summaries.append("Cache size: %s" % size_human)
        metrics["size"] = float(size_bytes)
        details_lines.append("Size: %s" % size_human)

    if "arc_meta_used" in section and "arc_meta_limit" in section and "arc_meta_max" in section:
        used = float(section["arc_meta_used"])
        limit = float(section["arc_meta_limit"])
        max_ = float(section["arc_meta_max"])
        summaries.append("Arc Meta used/limit/max")
        metrics["arc_meta_used"] = used
        metrics["arc_meta_limit"] = limit
        metrics["arc_meta_max"] = max_
        details_lines.append("Arc Meta: used %s, limit %s, max %s" % (
            format_bytes(used), format_bytes(limit), format_bytes(max_)))

    if "l2_size" in section:
        l2_size = float(section["l2_size"])
        metrics["l2_size"] = l2_size
        if l2_size > 0:
            summaries.append("L2 size: %s" % format_bytes(l2_size))
            details_lines.append("L2 size: %s" % format_bytes(l2_size))

            l2_hits = section.get("l2_hits")
            l2_misses = section.get("l2_misses")
            if l2_hits != None and l2_misses != None:
                l2_total = l2_hits + l2_misses
                if l2_total > 0:
                    l2_ratio = float(l2_hits) / l2_total * 100.0
                    l2_summary = "L2 hit ratio: %f%%" % l2_ratio
                    summaries.append(l2_summary)
                    metrics["l2_hit_ratio"] = l2_ratio
                    details_lines.append(l2_summary)
                else:
                    summaries.append("No L2 hits or misses")
                    details_lines.append("No L2 hits or misses")
            else:
                summaries.append("No info about L2 hit ratio available")
                details_lines.append("No info about L2 hit ratio available")
        else:
            summaries.append("L2 size: 0 B")
            details_lines.append("No L2 cache (size = 0)")
    else:
        summaries.append("No info about L2 size available")
        details_lines.append("No info about L2 size available")

    state = "OK"
    return {"changed": False,
            "msg": "; ".join(summaries),
            "data": {"state": state, "metrics": metrics, "details": "\n".join(details_lines)}}
