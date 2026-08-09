# cephosd.star — translated Checkmk check: Ceph OSD usage, PGs, latency

# Ceph CLI usage: ceph df [detail] and ceph osd perf
# We probe with `ceph` binary; rc==127 => not installed/host not a Ceph client

def _render_ms(seconds):
    return "%dms" % (seconds * 1000.0 + 0.5)

def _grade_level(value, warn, crit, direction):
    # direction: "upper" => warn/crit when value >= level
    #            "lower" => warn/crit when value <= level
    if direction == "upper":
        if crit != None and value >= crit:
            return "CRIT"
        if warn != None and value >= warn:
            return "WARN"
    else:
        if crit != None and value <= crit:
            return "CRIT"
        if warn != None and value <= warn:
            return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

def _ceph_installed(ctx):
    res = ctx.run(["ceph", "--version"], mutates=False)
    return res.rc == 0

def _ceph_df_json(ctx):
    res = ctx.run(["ceph", "df", "detail", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    obj = json.decode(res.stdout)
    return obj

def _ceph_osd_perf_json(ctx):
    res = ctx.run(["ceph", "osd", "perf", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    obj = json.decode(res.stdout)
    return obj

def _parse_osds(df_detail):
    # df_detail: {"nodes":[{"id":N,"device_class":...,"kb":N,"kb_avail":N,"pgs":N,"status":"up"},...]}
    nodes = df_detail.get("nodes", []) if df_detail else []
    out = {}
    for raw in nodes:
        osd_id = raw.get("id")
        if osd_id == None:
            continue
        key = str(osd_id)
        osd = {
            "id": osd_id,
            "device_class": raw.get("device_class"),
            "size_mb": float(raw.get("kb", 0)) / 1024.0 if raw.get("kb") != None else 0.0,
            "avail_mb": float(raw.get("kb_avail", 0)) / 1024.0 if raw.get("kb_avail") != None else 0.0,
            "pgs": raw.get("pgs"),
            "status": raw.get("status"),
        }
        out[key] = osd
    return out

def _parse_perf(osd_perf):
    # osd_perf: {"osd_perf_infos":[{"id":N,"perf_stats":{"apply_latency_ms":F,"commit_latency_ms":F}},...]}
    infos = osd_perf.get("osd_perf_infos", []) if osd_perf else []
    out = {}
    for raw in infos:
        osd_id = raw.get("id")
        if osd_id == None:
            continue
        key = str(osd_id)
        ps = raw.get("perf_stats", {})
        out[key] = {
            "apply": ps.get("apply_latency_ms"),
            "commit": ps.get("commit_latency_ms"),
        }
    return out

def _discover(ctx, params):
    if not _ceph_installed(ctx):
        return {"changed": False, "msg": "ceph not installed", "data": {"discovery": [], "host_labels": {}}}
    df_detail = _ceph_df_json(ctx)
    if df_detail == None:
        return {"changed": False, "msg": "no ceph df data", "data": {"discovery": [], "host_labels": {}}}
    osds = _parse_osds(df_detail)
    discovery = []
    for key, osd in osds.items():
        entry = {"item": key, "params": {"warn": 80, "crit": 90}, "metrics": ["used_percent", "num_pgs", "apply_latency", "commit_latency"]}
        labels = []
        if osd.get("device_class") != None:
            labels.append({"cephosd/device_class": osd["device_class"]})
        if labels:
            entry["service_labels"] = labels[0]
        discovery.append(entry)
    host_labels = {}
    if osds:
        host_labels["cmk/ceph/osd"] = "yes"
    return {"changed": False, "msg": "discovered %d OSDs" % len(discovery), "data": {"discovery": discovery, "host_labels": host_labels}}

def _check(ctx, params):
    item = params.get("item", "")
    if not _ceph_installed(ctx):
        return {"changed": False, "msg": "ceph not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    df_detail = _ceph_df_json(ctx)
    if df_detail == None:
        return {"changed": False, "msg": "could not read ceph df", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    osds = _parse_osds(df_detail)
    osd = osds.get(item) if item else None
    if osd == None:
        return {"changed": False, "msg": "no such OSD: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size_mb = osd.get("size_mb", 0.0)
    avail_mb = osd.get("avail_mb", 0.0)
    used_mb = size_mb - avail_mb
    used_percent = 0.0
    if size_mb > 0:
        used_percent = (used_mb / size_mb) * 100.0

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    state = _grade_level(used_percent, warn, crit, "upper")
    metrics = {"used_percent": used_percent}
    details_parts = ["Size: %f MB, Avail: %f MB, Used: %f MB (%f%%)" % (size_mb, avail_mb, used_mb, used_percent)]

    pgs = osd.get("pgs")
    if pgs != None:
        metrics["num_pgs"] = pgs
        details_parts.append("PGs: %d" % pgs)

    status = osd.get("status")
    if status != None:
        st = "OK" if status == "up" else "WARN"
        details_parts.append("Status: %s" % status)

    osd_perf = _parse_perf(_ceph_osd_perf_json(ctx))
    perf = osd_perf.get(item)
    if perf != None:
        apply_ms = perf.get("apply")
        commit_ms = perf.get("commit")
        if apply_ms != None:
            metrics["apply_latency"] = apply_ms
            details_parts.append("Apply latency: %s" % _render_ms(apply_ms / 1000.0))
        if commit_ms != None:
            metrics["commit_latency"] = commit_ms
            details_parts.append("Commit latency: %s" % _render_ms(commit_ms / 1000.0))

    if state == "CRIT" or st == "CRIT":
        final_state = "CRIT"
    elif state == "WARN" or st == "WARN":
        final_state = "WARN"
    else:
        final_state = "OK"

    return {"changed": False, "msg": "OSD %s: %s" % (item, details_parts[0]), "data": {"state": final_state, "metrics": metrics, "details": "; ".join(details_parts)}}