def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["redis-cli", "INFO", "persistence"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 instances (redis-cli error or no data)",
                    "data": {"discovery": []}}

        section_found = False
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("Persistence"):
                section_found = True
                break

        if section_found:
            return {"changed": False, "msg": "discovered 1 instance",
                    "data": {"discovery": [{"item": "", "params": {
                        "rdb_last_bgsave_state": 1,
                        "aof_last_rewrite_state": 1,
                        "rdb_changes_count": None
                    }, "metrics": []}]}}
        else:
            return {"changed": False, "msg": "discovered 0 instances (no Persistence section)",
                    "data": {"discovery": []}}

    item = params.get("item", "")
    res = ctx.run(["redis-cli", "INFO", "persistence"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "unable to retrieve persistence info",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    persistence_data = {}
    in_persistence = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("Persistence"):
            in_persistence = True
            continue
        if in_persistence:
            if stripped.startswith("#") and stripped != "# Persistence":
                in_persistence = False
                continue
            if "=" in stripped:
                key, _, val = stripped.partition("=")
                key = key.strip()
                # Try to convert to int
                if val.strip().lstrip("-").isdigit():
                    persistence_data[key] = int(val)
                else:
                    persistence_data[key] = val
                if stripped.startswith("#") and len(val.strip()) == 0:
                    break

    if not persistence_data or len(persistence_data) == 0:
        return {"changed": False, "msg": "no persistence data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rdb_last_bgsave_state = params.get("rdb_last_bgsave_state", 1)
    aof_last_rewrite_state = params.get("aof_last_rewrite_state", 1)
    rdb_changes_count = params.get("rdb_changes_count", None)

    summaries = []
    state = "OK"
    metrics = {}

    rdb_last_bgsave_status = persistence_data.get("rdb_last_bgsave_status")
    if rdb_last_bgsave_status != None:
        if rdb_last_bgsave_status != "ok":
            if state == "OK":
                state = "WARN" if rdb_last_bgsave_state == 1 else ("CRIT" if rdb_last_bgsave_state == 2 else "OK")
            infotext = "Last RDB save operation: faulty"
        else:
            infotext = "Last RDB save operation: successful"
        duration_val = persistence_data.get("rdb_last_bgsave_time_sec")
        if duration_val != None and duration_val != -1:
            infotext += " (Duration: %s)" % str(int(duration_val)) + " seconds"
        summaries.append(infotext)

    aof_last_bgrewrite_status = persistence_data.get("aof_last_bgrewrite_status")
    if aof_last_bgrewrite_status != None:
        if aof_last_bgrewrite_status != "ok":
            if state == "OK":
                state = "WARN" if aof_last_rewrite_state == 1 else ("CRIT" if aof_last_rewrite_state == 2 else "OK")
            infotext = "Last AOF rewrite operation: faulty"
        else:
            infotext = "Last AOF rewrite operation: successful"
        duration_val = persistence_data.get("aof_last_rewrite_time_sec")
        if duration_val != None and duration_val != -1:
            infotext += " (Duration: %s)" % str(int(duration_val)) + " seconds"
        summaries.append(infotext)

    rdb_last_save_time = persistence_data.get("rdb_last_save_time")
    if rdb_last_save_time != None:
        summaries.append("Last successful RDB save: %s seconds since epoch" % str(int(rdb_last_save_time)))

    rdb_changes_since_last_save = persistence_data.get("rdb_changes_since_last_save")
    if rdb_changes_since_last_save != None:
        if rdb_changes_since_last_save.strip().lstrip("-").isdigit():
            changes_val = int(rdb_changes_since_last_save)
        else:
            changes_val = 0
        if rdb_changes_count != None and len(rdb_changes_count) == 2:
            warn_level = rdb_changes_count[0]
            crit_level = rdb_changes_count[1]
            if changes_val >= crit_level:
                state = "CRIT"
                summaries.append("Number of changes since last dump: %s (CRIT above %s)" % (str(changes_val), str(crit_level)))
            elif changes_val >= warn_level:
                if state == "OK":
                    state = "WARN"
                summaries.append("Number of changes since last dump: %s (WARN above %s)" % (str(changes_val), str(warn_level)))
            else:
                summaries.append("Number of changes since last dump: %s" % str(changes_val))
        else:
            summaries.append("Number of changes since last dump: %s" % str(changes_val))
        metrics["changes_sld"] = changes_val

    summary = "; ".join(summaries)
    if not summary:
        summary = "Persistence info present but no actionable fields"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}