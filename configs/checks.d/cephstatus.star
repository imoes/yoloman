def main(ctx, params):
    # Read the Ceph status JSON from the agent
    res = ctx.run(["ceph", "status", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Unable to retrieve Ceph status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Guard: check if JSON is empty or whitespace before decoding
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Ceph status output is empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Decode JSON directly (no try/except — invalid JSON will cause fail() which is acceptable)
    status = json.decode(res.stdout)
    
    # Extract health info
    health = None
    if "health" in status and "status" in status["health"]:
        health_overall_ok = status["health"]["status"] == "HEALTH_OK"
        checks = []
        for name, check_data in status["health"].get("checks", {}).items():
            severity = "CRIT" if check_data["severity"] == "HEALTH_CRIT" else "WARN"
            checks.append({
                "name": name,
                "muted": bool(check_data.get("muted", False)),
                "message": check_data["summary"]["message"],
                "severity": severity
            })
        health = {"overall_ok": health_overall_ok, "checks": checks, "summaries": []}
    elif "health" in status and "overall_status" in status["health"]:
        overall_ok = status["health"]["overall_status"] == "HEALTH_OK"
        summaries = []
        for entry in status["health"]["summary"]:
            severity = "CRIT" if entry["severity"] == "HEALTH_CRIT" else "WARN"
            summaries.append({
                "severity": severity,
                "message": entry["summary"]
            })
        health = {"overall_ok": overall_ok, "checks": [], "summaries": summaries}
    elif "deployment_error" in status:
        return {
            "changed": False,
            "msg": str(status["deployment_error"]),
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    else:
        return {
            "changed": False,
            "msg": "Overall health information not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract OSD map info
    osdmap = None
    if "osdmap" in status and "osdmap" in status["osdmap"]:
        osdmap_data = status["osdmap"]["osdmap"]
        osdmap = {
            "full": bool(osdmap_data.get("full", False)),
            "nearfull": bool(osdmap_data.get("nearfull", False))
        }
    
    # Extract PG map info
    pgmap = None
    if "pgmap" in status:
        pgmap_data = status["pgmap"]
        MIB = 1024.0 * 1024.0
        pgmap = {
            "size_mb": None if pgmap_data.get("bytes_total") == None else float(pgmap_data["bytes_total"]) / MIB,
            "avail_mb": None if pgmap_data.get("bytes_avail") == None else float(pgmap_data["bytes_avail"]) / MIB,
            "num_objects": None if pgmap_data.get("num_objects") == None else int(pgmap_data["num_objects"]),
            "num_pgs": None if pgmap_data.get("num_pgs") == None else int(pgmap_data["num_pgs"]),
            "degraded_objects": None if pgmap_data.get("degraded_objects") == None else int(pgmap_data["degraded_objects"]),
            "degraded_total": None if pgmap_data.get("degraded_total") == None else int(pgmap_data["degraded_total"]),
            "misplaced_objects": None if pgmap_data.get("misplaced_objects") == None else int(pgmap_data["misplaced_objects"]),
            "misplaced_total": None if pgmap_data.get("misplaced_total") == None else int(pgmap_data["misplaced_total"]),
            "recovering": None if pgmap_data.get("recovering_bytes_per_sec") == None else float(pgmap_data["recovering_bytes_per_sec"]),
            "pgstates": [
                {"state_name": ps["state_name"], "count": int(ps["count"])}
                for ps in pgmap_data.get("pgs_by_state", [])
            ]
        }
    
    # Extract dashboard info (guard instead of try/except)
    dashboard = None
    if "mgrmap" in status and "services" in status["mgrmap"] and "dashboard" in status["mgrmap"]["services"]:
        dashboard = str(status["mgrmap"]["services"]["dashboard"])
    
    # Build result
    state = "OK"
    msg_parts = []
    metrics = {}
    
    # Health check
    if health != None:
        if health["overall_ok"]:
            msg_parts.append("Overall health OK")
        else:
            for check in health["checks"]:
                if not check["muted"]:
                    if check["severity"] == "CRIT":
                        state = "CRIT"
                    elif state == "OK":
                        state = "WARN"
                    msg_parts.append("%s: %s" % (check["name"], check["message"]))
                else:
                    msg_parts.append("%s: %s (muted)" % (check["name"], check["message"]))
            
            for summary in health["summaries"]:
                if summary["severity"] == "CRIT":
                    state = "CRIT"
                elif state == "OK":
                    state = "WARN"
                msg_parts.append(summary["message"])
    
    # OSD map check
    if osdmap != None:
        if osdmap["full"]:
            state = "CRIT"
            msg_parts.append("OSD map full")
        if osdmap["nearfull"]:
            if state == "OK":
                state = "WARN"
            msg_parts.append("OSD map near full")
    
    # PG map check
    if pgmap != None:
        # Filesystem usage
        if pgmap["avail_mb"] != None and pgmap["size_mb"] != None:
            size_mb = pgmap["size_mb"]
            avail_mb = pgmap["avail_mb"]
            used_percent = (size_mb - avail_mb) / size_mb * 100 if size_mb > 0 else 0
            
            warn = params.get("levels", [80.0, 90.0])
            warn_val = 80.0
            crit_val = 90.0
            if isinstance(warn, list) and len(warn) >= 2:
                warn_val = float(warn[0])
                crit_val = float(warn[1])
            elif isinstance(warn, (int, float)):
                warn_val = float(warn)
                crit_val = 90.0
            
            if used_percent >= crit_val:
                state = "CRIT"
            elif used_percent >= warn_val and state != "CRIT":
                state = "WARN"
            
            msg_parts.append("Size: %f MB, Usage: %f%%" % (size_mb, used_percent))
            metrics["size"] = size_mb
            metrics["used_percent"] = used_percent
            metrics["avail"] = avail_mb
        
        # Objects and placement groups
        if pgmap["num_objects"] != None:
            metrics["num_objects"] = pgmap["num_objects"]
            msg_parts.append("Objects: %d" % pgmap["num_objects"])
        
        if pgmap["num_pgs"] != None:
            metrics["num_pgs"] = pgmap["num_pgs"]
            msg_parts.append("Placement groups: %d" % pgmap["num_pgs"])
        
        # Degraded objects
        if pgmap["degraded_objects"] != None and pgmap["degraded_total"] != None:
            metrics["degraded_objects"] = pgmap["degraded_objects"]
        
        # Misplaced objects
        if pgmap["misplaced_objects"] != None and pgmap["misplaced_total"] != None:
            metrics["misplaced_objects"] = pgmap["misplaced_objects"]
        
        # Recovering
        if pgmap["recovering"] != None:
            metrics["recovering"] = pgmap["recovering"]
            msg_parts.append("Recovering: %f B/s" % pgmap["recovering"])
        
        # PG states
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
            "unknown": "unknown"
        }
        
        for pgstate in pgmap["pgstates"]:
            count = pgstate["count"]
            if not count:
                continue
            
            state_name = pgstate["state_name"]
            
            # Determine state
            if "inconsistent" in state_name or "incomplete" in state_name or "active" not in state_name:
                pg_state = "CRIT"
            elif "active+clean" not in state_name:
                pg_state = "WARN"
            elif "stale" in state_name:
                pg_state = "UNKNOWN"
            else:
                pg_state = "OK" if state_name in PG_METRICS_MAP else "UNKNOWN"
            
            # Update overall state
            if pg_state == "CRIT":
                state = "CRIT"
            elif pg_state == "WARN" and state != "CRIT":
                state = "WARN"
            elif pg_state == "UNKNOWN" and state == "OK":
                state = "UNKNOWN"
            
            msg_parts.append("PGs in %s: %d" % (state_name, count))
            
            if state_name in PG_METRICS_MAP:
                metrics[PG_METRICS_MAP[state_name]] = count
    
    # Dashboard info
    if dashboard != None:
        msg_parts.append("Dashboard: %s" % dashboard)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
