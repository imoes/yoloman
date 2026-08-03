def _usage_from_stats(stats):
    """
    Reproduce Usage.from_stats logic: compute used/avail/size in MB.
    """
    MIB = 1024.0 * 1024.0
    used_mb = 0.0
    avail_mb = 0.0
    size_mb = 0.0

    if "stored" in stats:
        # netto path
        used_mb = stats.get("stored", 0) / MIB
        max_avail = stats.get("max_avail")
        if max_avail != None and max_avail > 0:
            avail_mb = max_avail / MIB
            size_mb = avail_mb + used_mb
        else:
            perc_used = stats.get("percent_used")
            if perc_used != None and perc_used > 0:
                size_mb = used_mb / perc_used
                avail_mb = size_mb - used_mb
            else:
                avail_mb = 0.0
                size_mb = 0.0
    else:
        # brutto path
        used_mb = stats.get("bytes_used", 0) / MIB
        perc_used = stats.get("percent_used")
        if perc_used != None and perc_used > 0:
            size_mb = used_mb / perc_used
            avail_mb = size_mb - used_mb
        else:
            avail_mb = 0.0
            size_mb = 0.0

    return used_mb, avail_mb, size_mb


def _grade_df(used_mb, avail_mb, size_mb, params):
    """
    Grade a filesystem-style check using warn/crit percentage levels.
    """
    warn = params.get("warn")
    crit = params.get("crit")

    if type(warn) != "int" and type(warn) != "float":
        warn = None
    if type(crit) != "int" and type(crit) != "float":
        crit = None

    if size_mb > 0:
        perc = (used_mb / size_mb) * 100.0
    else:
        if used_mb > 0:
            perc = 100.0
        else:
            perc = 0.0

    if crit != None and perc >= crit:
        state = "CRIT"
    elif warn != None and perc >= warn:
        state = "WARN"
    elif size_mb == 0:
        state = "UNKNOWN"
    else:
        state = "OK"

    return state, perc


def _get_cephdf_section(ctx, params):
    """
    Retrieve the Ceph df JSON section.

    Tries the on-host ceph CLI first (real data source). Falls back to
    parsing a Checkmk-style <<<cephdf>>> section from stdin-style probe
    if present (simulated agent output). Returns the parsed dict or None.
    """
    # Try the ceph CLI — the real on-host source the agent plugin uses
    res = ctx.run(["ceph", "df", "detail", "--format", "json"], mutates=False)
    if res.rc == 0 and len(res.stdout) > 0:
        return json.decode(res.stdout)

    # Also accept the raw "ceph df" output for non-class variant
    res2 = ctx.run(["ceph", "df", "--format", "json"], mutates=False)
    if res2.rc == 0 and len(res2.stdout) > 0:
        return json.decode(res.stdout)

    return None


def _build_pools(section):
    """
    Build the pool mapping from raw ceph df detail output.
    ceph df detail JSON has pools as a list with 'name' and 'stats'.
    """
    pools = {}
    raw_pools = section.get("pools", [])
    if type(raw_pools) == "list":
        for p in raw_pools:
            name = p.get("name")
            if name == None:
                continue
            stats = p.get("stats", {})
            cleaned_stats = {}
            for k in stats:
                v = stats[k]
                cleaned_stats[k] = v
            pools[name] = {
                "id": p.get("id", 0),
                "name": name,
                "stats": cleaned_stats,
            }
    return pools


def _build_stats_by_class(section):
    """
    Build stats_by_class mapping from raw ceph df detail output.
    """
    stats_by_class = {}
    raw_classes = section.get("stats_by_class", {})
    if type(raw_classes) == "dict":
        for cls in raw_classes:
            raw_stats = raw_classes[cls]
            cleaned = {}
            for k in raw_stats:
                cleaned[k] = raw_stats[k]
            stats_by_class[cls] = cleaned
    return stats_by_class


def main(ctx, params):
    if params.get("_discover"):
        section = _get_cephdf_section(ctx, params)
        if section == None:
            return {
                "changed": False,
                "msg": "ceph not running or no data available",
                "data": {"discovery": []},
            }

        pools = _build_pools(section)
        stats_by_class = _build_stats_by_class(section)

        discovery = []

        # Discover pools (cephdf check)
        for pool_name in pools:
            stats = pools[pool_name].get("stats", {})
            metrics = ["used_mb", "avail_mb", "size_mb", "used_percent"]
            if "objects" in stats:
                metrics.append("objects")
            discovery.append({
                "item": pool_name,
                "params": {"warn": 80, "crit": 90},
                "metrics": metrics,
            })

        # Discover device classes (cephdfclass check)
        for cls in stats_by_class:
            discovery.append({
                "item": cls,
                "params": {"warn": 80, "crit": 90},
                "metrics": ["used_mb", "avail_mb", "size_mb", "used_percent"],
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE
    section = _get_cephdf_section(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "ceph not running or no data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    item = params.get("item", "")
    pools = _build_pools(section)
    stats_by_class = _build_stats_by_class(section)

    # Check pool (cephdf)
    pool = pools.get(item)
    if pool != None:
        used_mb, avail_mb, size_mb = _usage_from_stats(pool.get("stats", {}))
        state, perc = _grade_df(used_mb, avail_mb, size_mb, params)
        metrics = {
            "used_mb": int(used_mb),
            "avail_mb": int(avail_mb),
            "size_mb": int(size_mb),
            "used_percent": int(perc),
        }
        if "objects" in pool.get("stats", {}):
            metrics["objects"] = pool["stats"].get("objects", 0)
        return {
            "changed": False,
            "msg": "Size: %f MB, Used: %f MB (%f%%), Avail: %f MB" % (
                size_mb, used_mb, perc, avail_mb),
            "data": {"state": state, "metrics": metrics, "details": ""},
        }

    # Check device class (cephdfclass)
    cls_stats = stats_by_class.get(item)
    if cls_stats != None:
        MIB = 1024.0 * 1024.0
        avail_mb = cls_stats.get("total_avail_bytes", 0) / MIB
        size_mb = cls_stats.get("total_bytes", 0) / MIB
        used_mb = size_mb - avail_mb
        state, perc = _grade_df(used_mb, avail_mb, size_mb, params)
        metrics = {
            "used_mb": int(used_mb),
            "avail_mb": int(avail_mb),
            "size_mb": int(size_mb),
            "used_percent": int(perc),
        }
        return {
            "changed": False,
            "msg": "Size: %f MB, Used: %f MB (%f%%), Avail: %f MB" % (
                size_mb, used_mb, perc, avail_mb),
            "data": {"state": state, "metrics": metrics, "details": ""},
        }

    return {
        "changed": False,
        "msg": "no such pool or class: %s" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }