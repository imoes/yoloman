def main(ctx, params):
    # --- IBM SVC systemstats check: Latency %s Total ---
    # The monitored device is an IBM storage array (SVC). Its stats are not
    # available locally on the host, so we read the same CSV-style data the
    # Checkmk agent plugin would emit. When the source is missing we report
    # absence (empty discovery / UNKNOWN).

    src = params.get("source", "/var/lib/cmk/ibm_svc_systemstats")

    def _read_source():
        if not ctx.file_exists(src):
            return None
        content = ctx.file_read(src)
        rows = []
        for line in content.splitlines():
            line = line.strip()
            if not line:
                continue
            rows.append(line.split(","))
        return rows

    def _parse(rows):
        disks = {}
        cpu_pc = None
        total_cache_pc = None
        write_cache_pc = None
        if rows == None:
            return disks, cpu_pc, total_cache_pc, write_cache_pc
        for row in rows:
            if len(row) < 3:
                continue
            stat_name = row[0]
            stat_current = row[1]
            if stat_name == "cpu_pc":
                cpu_pc = int(stat_current) if stat_current.lstrip("-").isdigit() else None
            elif stat_name == "total_cache_pc":
                total_cache_pc = int(stat_current) if stat_current.lstrip("-").isdigit() else None
            elif stat_name == "write_cache_pc":
                write_cache_pc = int(stat_current) if stat_current.lstrip("-").isdigit() else None
            elif stat_name.startswith("vdisk_"):
                short = stat_name.replace("vdisk_", "")
                disks.setdefault("VDisks", {})[short] = float(stat_current)
            elif stat_name.startswith("mdisk_"):
                short = stat_name.replace("mdisk_", "")
                disks.setdefault("MDisks", {})[short] = float(stat_current)
            elif stat_name.startswith("drive_"):
                short = stat_name.replace("drive_", "")
                disks.setdefault("Drives", {})[short] = float(stat_current)
        return disks, cpu_pc, total_cache_pc, write_cache_pc

    if params.get("_discover"):
        rows = _read_source()
        if rows == None:
            return {"changed": False, "msg": "no ibm_svc_systemstats source on host",
                    "data": {"discovery": [], "host_labels": {}}}
        disks, cpu_pc, total_cache_pc, write_cache_pc = _parse(rows)
        out = []
        for item in disks:
            out.append({"item": item, "params": {}, "metrics": ["read_latency", "write_latency"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    rows = _read_source()
    if rows == None:
        return {"changed": False, "msg": "no ibm_svc_systemstats source on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    disks, cpu_pc, total_cache_pc, write_cache_pc = _parse(rows)
    if item not in disks or len(item) == 0:
        return {"changed": False, "msg": "item not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    d = disks[item]
    r_ms = d.get("r_ms", 0)
    w_ms = d.get("w_ms", 0)

    warn_r = params.get("read", None)
    crit_r = params.get("crit_read", None)
    warn_w = params.get("write", None)
    crit_w = params.get("crit_write", None)

    def _level(value, warn, crit):
        if crit != None and value >= crit:
            return "CRIT"
        if warn != None and value >= warn:
            return "WARN"
        return "OK"

    # For Latency %s Total we emit both read and write latencies.
    # We grade on whichever levels are configured; default to OK if none given.
    state_r = _level(r_ms, warn_r, crit_r)
    state_w = _level(w_ms, warn_w, crit_w)

    if state_r == "CRIT" or state_w == "CRIT":
        state = "CRIT"
    elif state_r == "WARN" or state_w == "WARN":
        state = "WARN"
    else:
        state = "OK"

    msg = "read latency %f ms, write latency %f ms" % (r_ms, w_ms)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"read_latency": r_ms, "write_latency": w_ms},
                     "details": ""}}