def _read_arcstats(ctx, path):
    res = ctx.run(["cat", path], mutates=False)
    data = {}
    if res.rc != 0 or res.stdout == "":
        return data
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            data[parts[0]] = int(parts[1])
    return data

def _bytes_readable(n):
    if n >= (1024 * 1024):
        return "%d MB" % (n / (1024 * 1024))
    if n >= 1024:
        return "%d KB" % (n / 1024)
    return "%d Bytes" % n

def _hit_ratio(hits, misses):
    total = hits + misses
    if total == 0:
        return None
    return float(hits) / total * 100.0

def main(ctx, params):
    if params.get("_discover"):
        section = _read_arcstats(ctx, "/proc/spl/kstat/zfs/arcstats")
        if len(section) == 0:
            return {"changed": False, "msg": "no ZFS arcstats found",
                    "data": {"discovery": []}}
        discovery = []
        if section.get("hits") != None and section.get("misses") != None:
            metrics = ["hit_ratio", "size", "arc_meta_used", "arc_meta_limit", "arc_meta_max"]
            discovery.append({"item": "", "params": {}, "metrics": metrics})
        if section.get("l2_size") != None and section["l2_size"] > 0:
            l2_metrics = ["l2_hit_ratio", "l2_size"]
            discovery.append({"item": "l2", "params": {}, "metrics": l2_metrics})
        msg = "discovered %d items" % len(discovery)
        return {"changed": False, "msg": msg, "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _read_arcstats(ctx, "/proc/spl/kstat/zfs/arcstats")
    if len(section) == 0:
        return {"changed": False,
                "msg": "no ZFS arcstats file found (ZFS not loaded?)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    metrics = {}

    if item == "":
        parts = []
        if "hits" in section and "misses" in section:
            ratio = _hit_ratio(section["hits"], section["misses"])
            if ratio != None:
                metrics["hit_ratio"] = ratio
                parts.append("Overall Hit Ratio: %f%%" % ratio)
            else:
                parts.append("No Hits or Misses")
        if "prefetch_data_hits" in section and "prefetch_data_misses" in section:
            ratio = _hit_ratio(section["prefetch_data_hits"], section["prefetch_data_misses"])
            if ratio != None:
                metrics["prefetch_data_hit_ratio"] = ratio
                parts.append("Prefetch Data Hit Ratio: %f%%" % ratio)
        if "prefetch_metadata_hits" in section and "prefetch_metadata_misses" in section:
            ratio = _hit_ratio(section["prefetch_metadata_hits"], section["prefetch_metadata_misses"])
            if ratio != None:
                metrics["prefetch_metadata_hit_ratio"] = ratio
                parts.append("Prefetch Metadata Hit Ratio: %f%%" % ratio)
        if "size" in section:
            size_bytes = section["size"]
            metrics["size"] = float(size_bytes)
            parts.append("Cache size: %s" % _bytes_readable(size_bytes))
        if "l2_size" in section:
            metrics["l2_size"] = float(section["l2_size"])
        if "arc_meta_used" in section and "arc_meta_limit" in section and "arc_meta_max" in section:
            metrics["arc_meta_used"] = float(section["arc_meta_used"])
            metrics["arc_meta_limit"] = float(section["arc_meta_limit"])
            metrics["arc_meta_max"] = float(section["arc_meta_max"])
            parts.append("Arc Meta %s used, Limit %s, Max %s" % (
                _bytes_readable(section["arc_meta_used"]),
                _bytes_readable(section["arc_meta_limit"]),
                _bytes_readable(section["arc_meta_max"]),
            ))
        summary = ", ".join(parts)
        if summary == "":
            summary = "no ARC statistics available"
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": metrics, "details": ""}}

    if item == "l2":
        parts = []
        if "l2_hits" in section and "l2_misses" in section:
            total = section["l2_hits"] + section["l2_misses"]
            if total > 0:
                ratio = float(section["l2_hits"]) / total * 100.0
                metrics["l2_hit_ratio"] = ratio
                parts.append("L2 hit ratio: %f%%" % ratio)
            else:
                parts.append("No L2 hits or misses")
        else:
            return {"changed": False,
                    "msg": "No info about L2 hit ratio available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if "l2_size" in section:
            metrics["l2_size"] = float(section["l2_size"])
            parts.append("L2 size: %s" % _bytes_readable(section["l2_size"]))
        summary = ", ".join(parts)
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": metrics, "details": ""}}

    return {"changed": False, "msg": "unknown item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}