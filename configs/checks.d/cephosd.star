def main(ctx, params):
    _KIB = 1024.0

    def _render_ms(seconds):
        return "%dms" % (seconds * 1000.0)

    if params.get("_discover"):
        res = ctx.run(["ceph", "osd", "df", "-f", "json"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "failed to get OSD df data",
                    "data": {"discovery": []}}
        df_data = json.decode(res.stdout)

        res_perf = ctx.run(["ceph", "osd", "perf", "-f", "json"], mutates=False)
        perf_data = []
        if res_perf.rc == 0 and res_perf.stdout.strip():
            perf_data = json.decode(res_perf.stdout).get("osd_perf_infos", [])

        items = []
        for raw in df_data.get("nodes", ()):
            item = str(raw.get("id", ""))
            osd_perf = None
            for p in perf_data:
                if str(p.get("id", "")) == item:
                    osd_perf = p
                    break
            perf_stats = osd_perf.get("perf_stats", {}) if osd_perf else {}
            apply_lat_str = str(perf_stats.get("apply_latency_ms", ""))
            commit_lat_str = str(perf_stats.get("commit_latency_ms", ""))
            apply_latency_ms = float(apply_lat_str) if apply_lat_str.replace(".", "").isdigit() else 0
            commit_latency_ms = float(commit_lat_str) if commit_lat_str.replace(".", "").isdigit() else 0

            size_kb_str = str(raw.get("kb", "0"))
            avail_kb_str = str(raw.get("kb_avail", "0"))
            osd = {
                "id": raw.get("id"),
                "device_class": raw.get("device_class"),
                "size_mb": float(size_kb_str) / _KIB if size_kb_str.replace(".", "").isdigit() else 0,
                "avail_mb": float(avail_kb_str) / _KIB if avail_kb_str.replace(".", "").isdigit() else 0,
                "pgs": int(raw.get("pgs")) if str(raw.get("pgs", "")).isdigit() else None,
                "status": raw.get("status"),
                "apply_latency_ms": apply_latency_ms,
                "commit_latency_ms": commit_latency_ms,
            }

            metrics = ["size", "avail", "used_percent", "num_pgs"]
            if osd["apply_latency_ms"] != 0 or osd["commit_latency_ms"] != 0:
                metrics.extend(["apply_latency", "commit_latency"])
            items.append({
                "item": item,
                "params": {},
                "metrics": metrics,
            })
        return {"changed": False, "msg": "discovered %d OSDs" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    res = ctx.run(["ceph", "osd", "df", "-f", "json"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "failed to get OSD df data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    df_data = json.decode(res.stdout)

    osd = None
    for raw in df_data.get("nodes", ()):
        if str(raw.get("id", "")) == item:
            osd = raw
            break
    if osd == None:
        return {"changed": False, "msg": "OSD %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size_kb_str = str(osd.get("kb", "0"))
    avail_kb_str = str(osd.get("kb_avail", "0"))
    size_mb = float(size_kb_str) / _KIB if size_kb_str.replace(".", "").isdigit() else 0
    avail_mb = float(avail_kb_str) / _KIB if avail_kb_str.replace(".", "").isdigit() else 0
    used_mb = size_mb - avail_mb
    used_percent = (used_mb / size_mb * 100) if size_mb > 0 else 0
    pgs_str = str(osd.get("pgs", ""))
    pgs = int(pgs_str) if pgs_str.isdigit() else None
    status = osd.get("status")

    res_perf = ctx.run(["ceph", "osd", "perf", "-f", "json"], mutates=False)
    apply_latency_ms = 0.0
    commit_latency_ms = 0.0
    if res_perf.rc == 0 and res_perf.stdout.strip():
        perf_data = json.decode(res_perf.stdout).get("osd_perf_infos", [])
        for p in perf_data:
            if str(p.get("id", "")) == item:
                ps = p.get("perf_stats", {})
                apply_lat_str = str(ps.get("apply_latency_ms", ""))
                commit_lat_str = str(ps.get("commit_latency_ms", ""))
                apply_latency_ms = float(apply_lat_str) if apply_lat_str.replace(".", "").isdigit() else 0
                commit_latency_ms = float(commit_lat_str) if commit_lat_str.replace(".", "").isdigit() else 0
                break

    warn_pct = params.get("levels", (80.0, 90.0))
    crit_pct = warn_pct[1]
    warn_pct = warn_pct[0]
    state = "OK"
    if used_percent >= crit_pct:
        state = "CRIT"
    elif used_percent >= warn_pct:
        state = "WARN"

    metrics = {
        "size": int(size_mb * 1024 * 1024),
        "avail": int(avail_mb * 1024 * 1024),
        "used_percent": used_percent,
    }

    msg_parts = []
    msg_parts.append("Size: %f MB" % size_mb)
    msg_parts.append("Used: %f MB (%f%%)" % (used_mb, used_percent))
    if pgs != None:
        metrics["num_pgs"] = pgs
        msg_parts.append("PGs: %d" % pgs)
    if state == "WARN":
        msg_parts.append("Warning: High usage")
    elif state == "CRIT":
        msg_parts.append("Critical: Very high usage")

    if status:
        if status == "up":
            msg_parts.append("Status: %s" % status)
        else:
            state = "WARN"
            msg_parts.append("Status: %s (non-up)" % status)

    if apply_latency_ms != 0 or commit_latency_ms != 0:
        apply_latency = apply_latency_ms / 1000.0
        commit_latency = commit_latency_ms / 1000.0
        metrics["apply_latency"] = apply_latency
        metrics["commit_latency"] = commit_latency
        msg_parts.append("Apply latency: %s" % _render_ms(apply_latency))
        msg_parts.append("Commit latency: %s" % _render_ms(commit_latency))

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
