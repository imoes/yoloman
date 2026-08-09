# ===== Starlark translation of cmk Ceph status check =====
# Reads live ceph health data via `ceph status --format json` (the same
# data the Checkmk agent plugin's cephstatus section exposes) and reports
# health, OSD map, PG map utilization, PG states, and dashboard URL.
# READ-ONLY: never mutates state, always changed=False.

# PG state string -> metric name (mirrors PG_METRICS_MAP from constants.py)
PG_METRICS_MAP = {
    "activating+undersized": "activating_undersized",
    "activating+undersized+degraded": "activating_undersized_degraded",
    "active+clean": "active_clean",
    "active+clean+inconsistent": "active_clean_inconsistent",
    "active+clean+laggy": "active_clean_laggy",
    "active+clean+remapped": "active_clean_remapped",
    "active+clean+scrubbing": "active_clean_scrubbing",
    "active+clean+scrubbing+deep": "active_clean_scrubbing_deep",
    "active+clean+scrubbing+deep+repair": "active_clean_scrubbing_deep_repair",
    "active+clean+scrubbing+deep+snaptrim_wait": "active_clean_scrubbing_deep_snaptrim_wait",
    "active+clean+snaptrim": "active_clean_snaptrim",
    "active+clean+snaptrim_wait": "active_clean_snaptrim_wait",
    "active+clean+wait": "active_clean_wait",
    "active+degraded": "active_degraded",
    "active+recovering": "active_recovering",
    "active+recovering+degraded": "active_recovering_degraded",
    "active+recovering+degraded+inconsistent": "active_recovering_degraded_inconsistent",
    "active+recovering+degraded+remapped": "active_recovering_degraded_remapped",
    "active+recovering+remapped": "active_recovering_remapped",
    "active+recovering+undersized": "active_recovering_undersized",
    "active+recovering+undersized+degraded+remapped": "active_recovering_undersized_degraded_remapped",
    "active+recovering+undersized+remapped": "active_recovering_undersized_remapped",
    "active+recovery_wait": "active_recovery_wait",
    "active+recovery_wait+degraded": "active_recovery_wait_degraded",
    "active+recovery_wait+degraded+inconsistent": "active_recovery_wait_degraded_inconsistent",
    "active+recovery_wait+degraded+remapped": "active_recovery_wait_degraded_remapped",
    "active+recovery_wait+remapped": "active_recovery_wait_remapped",
    "active+recovery_wait+undersized+degraded": "active_recovery_wait_undersized_degraded",
    "active+recovery_wait+undersized+degraded+remapped": "active_recovery_wait_undersized_degraded_remapped",
    "active+recovery_wait+undersized+remapped": "active_recovery_wait_undersized_remapped",
    "active+remapped": "active_remapped",
    "active+remapped+backfill_toofull": "active_remapped_backfill_toofull",
    "active+remapped+backfill_wait": "active_remapped_backfill_wait",
    "active+remapped+backfill_wait+backfill_toofull": "active_remapped_backfill_wait_backfill_toofull",
    "active+remapped+backfilling": "active_remapped_backfilling",
    "active+remapped+inconsistent+backfill_toofull": "active_remapped_inconsistent_backfill_toofull",
    "active+remapped+inconsistent+backfill_wait": "active_remapped_inconsistent_backfill_wait",
    "active+remapped+inconsistent+backfilling": "active_remapped_inconsistent_backfilling",
    "active+undersized": "active_undersized",
    "active+undersized+degraded": "active_undersized_degraded",
    "active+undersized+degraded+inconsistent": "active_undersized_degraded_inconsistent",
    "active+undersized+degraded+remapped+backfill_toofull": "active_undersized_degraded_remapped_backfill_toofull",
    "active+undersized+degraded+remapped+backfill_wait": "active_undersized_degraded_remapped_backfill_wait",
    "active+undersized+degraded+remapped+backfill_wait+backfill_toofull": "active_undersized_degraded_remapped_backfill_wait_backfill_toofull",
    "active+undersized+degraded+remapped+backfilling": "active_undersized_degraded_remapped_backfilling",
    "active+undersized+degraded+remapped+inconsistent+backfill_toofull": "active_undersized_degraded_remapped_inconsistent_backfill_toofull",
    "active+undersized+degraded+remapped+inconsistent+backfill_wait": "active_undersized_degraded_remapped_inconsistent_backfill_wait",
    "active+undersized+degraded+remapped+inconsistent+backfilling": "active_undersized_degraded_remapped_inconsistent_backfilling",
    "active+undersized+remapped": "active_undersized_remapped",
    "active+undersized+remapped+backfill_toofull": "active_undersized_remapped_backfill_toofull",
    "active+undersized+remapped+backfill_wait": "active_undersized_remapped_backfill_wait",
    "active+undersized+remapped+backfilling": "active_undersized_remapped_backfilling",
    "down": "down",
    "incomplete": "incomplete",
    "peering": "peering",
    "remapped+peering": "remapped_peering",
    "stale+active+clean": "stale_active_clean",
    "stale+active+undersized": "stale_active_undersized",
    "stale+active+undersized+degraded": "stale_active_undersized_degraded",
    "stale+undersized+degraded+peered": "stale_undersized_degraded_peered",
    "stale+undersized+peered": "stale_undersized_peered",
    "undersized+degraded+peered": "undersized_degraded_peered",
    "undersized+peered": "undersized_peered",
    "unknown": "unknown",
}

MIB = 1024.0 * 1024.0


def _make_state(name):
    if "inconsistent" in name or "incomplete" in name or "active" not in name:
        return "CRIT"
    if "active+clean" not in name:
        return "WARN"
    if "stale" in name:
        return "UNKNOWN"
    return "OK" if name in PG_METRICS_MAP else "UNKNOWN"


def _grade_upper(value, warn, crit):
    if value == None:
        return "OK"
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"


def _grade_lower(value, warn, crit):
    if value == None:
        return "OK"
    if crit != None and value <= crit:
        return "CRIT"
    if warn != None and value <= warn:
        return "WARN"
    return "OK"


def _get_fs_levels(params):
    levels = params.get("levels")
    if isinstance(levels, dict):
        up = levels.get("used_percentage")
        if isinstance(up, dict):
            return up.get("warn", 80), up.get("crit", 90)
    return params.get("warn", 80), params.get("crit", 90)


def _check_health(health):
    if health == None:
        return [], {}, "UNKNOWN", "Overall health information not found", ""

    status = health.get("status")
    overall_ok = (status == "HEALTH_OK")

    if overall_ok:
        return [{"state": "OK", "summary": "Overall health OK"}], {}, "OK", "Overall health OK", ""

    worst = "OK"
    details = ""
    checks = health.get("checks", {})
    summaries = health.get("summary", [])

    if not isinstance(summaries, list):
        summaries = []

    for check_name in checks:
        raw_check = checks[check_name]
        if not isinstance(raw_check, dict):
            continue
        muted = bool(raw_check.get("muted"))
        sev = raw_check.get("severity", "HEALTH_WARN")
        severity = "WARN" if sev == "HEALTH_WARN" else "CRIT"
        if muted:
            severity = "OK"
        summary_field = raw_check.get("summary", {})
        if isinstance(summary_field, dict):
            msg = str(check_name) + ": " + str(summary_field.get("message", ""))
        else:
            msg = str(check_name)
        if muted:
            msg = msg + " (muted)"
        if details:
            details = details + "\n" + msg
        else:
            details = msg
        if severity == "CRIT":
            worst = "CRIT"
        elif severity == "WARN" and worst != "CRIT":
            worst = "WARN"

    for data in summaries:
        if not isinstance(data, dict):
            continue
        sev = data.get("severity", "HEALTH_WARN")
        severity = "WARN" if sev == "HEALTH_WARN" else "CRIT"
        msg = str(data.get("summary", ""))
        if details:
            details = details + "\n" + msg
        else:
            details = msg
        if severity == "CRIT":
            worst = "CRIT"
        elif severity == "WARN" and worst != "CRIT":
            worst = "WARN"

    if not checks and not summaries:
        return [{"state": "UNKNOWN", "summary": "Overall Health status not found"}], {}, "UNKNOWN", "Overall Health status not found", details

    return [], {}, worst, "Ceph health: " + str(status), details


def _check_osdmap(osdmap):
    results = []
    if osdmap == None:
        return results
    if osdmap.get("full"):
        results.append({"state": "CRIT", "summary": "OSD map full"})
    if osdmap.get("nearfull"):
        results.append({"state": "WARN", "summary": "OSD map near full"})
    return results


def _check_pgmap(pgmap, params):
    results = []
    metrics = {}

    size_mb_raw = pgmap.get("bytes_total")
    avail_mb_raw = pgmap.get("bytes_avail")
    if size_mb_raw != None and avail_mb_raw != None:
        size_mb_val = float(size_mb_raw) / MIB
        avail_mb_val = float(avail_mb_raw) / MIB
        used_mb = size_mb_val - avail_mb_val
        used_pct = 0.0
        if size_mb_val > 0:
            used_pct = (used_mb / size_mb_val) * 100.0
        warn_lvl, crit_lvl = _get_fs_levels(params)
        state = "CRIT" if used_pct >= crit_lvl else ("WARN" if used_pct >= warn_lvl else "OK")
        results.append({"state": state, "summary": "%s: %f%% used (%f/%f MB)" % ("Status", used_pct, used_mb, size_mb_val)})
        metrics["used_percent"] = used_pct

    num_objects = pgmap.get("num_objects")
    if num_objects != None:
        results.append({"state": "OK", "summary": "Objects: %d" % num_objects})
        metrics["num_objects"] = num_objects

    num_pgs = pgmap.get("num_pgs")
    if num_pgs:
        results.append({"state": "OK", "summary": "Placement groups: %d" % num_pgs})
        metrics["num_pgs"] = num_pgs

    degraded_objects = pgmap.get("degraded_objects")
    degraded_total = pgmap.get("degraded_total")
    if degraded_objects != None and degraded_total != None:
        metrics["degraded_objects"] = degraded_objects

    misplaced_objects = pgmap.get("misplaced_objects")
    misplaced_total = pgmap.get("misplaced_total")
    if misplaced_objects != None and misplaced_total != None:
        metrics["misplaced_objects"] = misplaced_objects

    recovering = pgmap.get("recovering_bytes_per_sec")
    if recovering != None and recovering > 0:
        results.append({"state": "OK", "summary": "Recovering: %f B/s" % float(recovering)})
        metrics["recovering"] = float(recovering)

    pgs_by_state = pgmap.get("pgs_by_state", [])
    if not isinstance(pgs_by_state, list):
        pgs_by_state = []
    worst = "OK"
    details = ""
    for pgstate in pgs_by_state:
        if not isinstance(pgstate, dict):
            continue
        state_name = str(pgstate.get("state_name", ""))
        count = int(pgstate.get("count", 0))
        if not count:
            continue
        pg_state = _make_state(state_name)
        results.append({"state": pg_state, "summary": "PGs in %s: %d" % (state_name, count)})
        metric_name = PG_METRICS_MAP.get(state_name)
        if metric_name != None:
            metrics[metric_name] = count
        if pg_state == "CRIT":
            worst = "CRIT"
        elif pg_state == "WARN" and worst != "CRIT":
            worst = "WARN"
        elif pg_state == "UNKNOWN" and worst not in ("CRIT", "WARN"):
            worst = "UNKNOWN"
        line = "PGs in " + state_name + ": " + str(count)
        if details:
            details = details + "\n" + line
        else:
            details = line

    return results, metrics, worst, "PG map", details


def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["ceph", "--version"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "ceph not installed", "data": {"discovery": [], "host_labels": {}}}

        res = ctx.run(["ceph", "status", "--format", "json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "ceph status not available", "data": {"discovery": [], "host_labels": {}}}
        if not res.stdout:
            return {"changed": False, "msg": "ceph status empty", "data": {"discovery": [], "host_labels": {}}}

        raw = json.decode(res.stdout)
        health_raw = raw.get("health")
        error = raw.get("deployment_error")
        if isinstance(health_raw, dict) or error != None:
            host_labels = {}
            if isinstance(health_raw, dict):
                host_labels["cmk/ceph/mon"] = "yes"
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "Status",
                            "params": {"levels": {"used_percentage": {"warn": 80, "crit": 90}}},
                            "metrics": ["used_percent", "num_objects", "num_pgs", "degraded_objects", "misplaced_objects", "recovering"],
                            "service_labels": {},
                        }
                    ],
                    "host_labels": host_labels,
                },
            }
        return {"changed": False, "msg": "no ceph health data", "data": {"discovery": [], "host_labels": {}}}

    # --- Check mode ---
    item = params.get("item", "")

    probe = ctx.run(["ceph", "--version"], mutates=False)
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "ceph: not installed (rc=%d)" % probe.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["ceph", "status", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "ceph: status data not available (rc=%d)" % res.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not res.stdout:
        return {
            "changed": False,
            "msg": "ceph: status data empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = json.decode(res.stdout)

    error = raw.get("deployment_error")
    if error != None:
        error = str(error)

    health_raw = raw.get("health")
    health = health_raw if isinstance(health_raw, dict) else None

    osdmap_raw = raw.get("osdmap")
    if isinstance(osdmap_raw, dict):
        osdmap_inner = osdmap_raw.get("osdmap")
        osdmap = osdmap_inner if isinstance(osdmap_inner, dict) else None
    else:
        osdmap = None

    pgmap_raw = raw.get("pgmap")
    pgmap = pgmap_raw if isinstance(pgmap_raw, dict) else None

    dashboard = None
    mgrmap = raw.get("mgrmap")
    if isinstance(mgrmap, dict):
        services = mgrmap.get("services")
        if isinstance(services, dict):
            dash_val = services.get("dashboard")
            if dash_val != None:
                dashboard = str(dash_val)

    worst = "OK"
    all_metrics = {}
    summaries = []
    details_parts = []

    # Health
    if health != None:
        h_results, h_metrics, h_worst, h_msg, h_details = _check_health(health)
        for r in h_results:
            summaries.append(r["summary"])
        for k in h_metrics:
            all_metrics[k] = h_metrics[k]
        if h_worst == "CRIT":
            worst = "CRIT"
        elif h_worst == "WARN" and worst != "CRIT":
            worst = "WARN"
        elif h_worst == "UNKNOWN" and worst not in ("CRIT", "WARN"):
            worst = "UNKNOWN"
        if h_details:
            details_parts.append("--- Health ---")
            details_parts.append(h_details)
    elif error != None:
        summaries.append(error)
        worst = "CRIT"
        details_parts.append("--- Error ---")
        details_parts.append(error)
    else:
        summaries.append("Overall health information not found")
        worst = "UNKNOWN"
        details_parts.append("--- Health ---")
        details_parts.append("Overall health information not found")

    # OSD map
    if osdmap != None:
        osd_results = _check_osdmap(osdmap)
        for r in osd_results:
            summaries.append(r["summary"])
            if r["state"] == "CRIT":
                worst = "CRIT"
            elif r["state"] == "WARN" and worst != "CRIT":
                worst = "WARN"
        details_parts.append("--- OSD Map ---")
        if osdmap.get("full"):
            details_parts.append("OSD map full")
        if osdmap.get("nearfull"):
            details_parts.append("OSD map near full")

    # PG map
    if pgmap != None:
        pg_results, pg_metrics, pg_worst, pg_msg, pg_details = _check_pgmap(pgmap, params)
        for r in pg_results:
            summaries.append(r["summary"])
        for k in pg_metrics:
            all_metrics[k] = pg_metrics[k]
        if pg_worst == "CRIT":
            worst = "CRIT"
        elif pg_worst == "WARN" and worst != "CRIT":
            worst = "WARN"
        elif pg_worst == "UNKNOWN" and worst not in ("CRIT", "WARN"):
            worst = "UNKNOWN"
        if pg_details:
            details_parts.append("--- PG Map ---")
            details_parts.append(pg_details)

    # Dashboard
    if dashboard != None:
        summaries.append("Dashboard: " + dashboard)
        details_parts.append("--- Dashboard ---")
        details_parts.append("URL: " + dashboard)

    msg = "; ".join(summaries) if summaries else "Ceph Status"
    details = "\n".join(details_parts) if details_parts else ""

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": worst, "metrics": all_metrics, "details": details},
    }