def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mkbackup", "list"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if res.stdout.strip() == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout.strip() != "" else []
        if type(data) != "list":
            data = []
        out = []
        for job in data:
            job_type = job.get("type", "system")
            if job_type == "system":
                job_id = job.get("id", "")
                if job_id != "":
                    out.append({"item": job_id, "params": {},
                                "metrics": ["backup_duration", "backup_avgspeed", "backup_size"]})
            elif job_type == "site":
                site_id = job.get("site_id", "")
                job_id = job.get("id", "")
                if site_id != "" and job_id != "":
                    item = site_id + " backup " + job_id
                    out.append({"item": item, "params": {},
                                "metrics": ["backup_duration", "backup_avgspeed", "backup_size"]})
        return {"changed": False, "msg": "discovered %d backups" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["mkbackup", "list"], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "no backup data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if type(data) != "list":
        data = []

    job_state = None
    for job in data:
        job_type = job.get("type", "system")
        if job_type == "system":
            if item == job.get("id", ""):
                job_state = job
                break
        elif job_type == "site":
            site_id = job.get("site_id", "")
            job_id = job.get("id", "")
            expected = site_id + " backup " + job_id
            if item == expected:
                job_state = job
                break

    if job_state == None:
        return {"changed": False, "msg": "backup job not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    now = 0
    stat_res = ctx.stat("/")
    if stat_res != None and stat_res.get("mtime") != None:
        now = int(stat_res.get("mtime"))
    else:
        date_res = ctx.run(["date", "+%s"], mutates=False)
        if date_res.rc == 0 and date_res.stdout.strip().isdigit():
            now = int(date_res.stdout.strip())
    started = job_state.get("started", 0)
    finished = job_state.get("finished", 0)
    dur = 0
    if started != 0 and finished != 0:
        dur = finished - started
    elif started != 0:
        dur = now - started

    state = "OK"
    msg_parts = []
    metrics = {}

    job_state_state = job_state.get("state", "")
    if job_state_state == "started" or job_state_state == "running":
        state = "OK"
        msg_parts.append("The job is running for %d seconds since %d" % (dur, started))
        metrics["backup_duration"] = dur
        metrics["backup_avgspeed"] = job_state.get("bytes_per_second", 0)
        if "size" in job_state:
            metrics["backup_size"] = job_state.get("size", 0)

        next_run = job_state.get("next_schedule")
        if next_run == "disabled":
            state = "WARN"
            msg_parts.append("Schedule is currently disabled")
        elif next_run != None:
            expected_time_with_buffer = next_run + 60 * 2
            if now > expected_time_with_buffer:
                state = "CRIT"
            msg_parts.append("Next run: %d" % next_run)

    elif job_state_state == "finished":
        if job_state.get("success") == False:
            state = "CRIT"
            msg_parts.append("Backup failed")
        else:
            state = "OK"
            msg_parts.append("Backup completed")

        msg_parts.append("it was running for %d seconds from %d till %d" % (dur, started, finished))
        metrics["backup_duration"] = dur
        metrics["backup_avgspeed"] = job_state.get("bytes_per_second", 0)

        if "size" in job_state and job_state.get("success", False) == True:
            msg_parts.append("Size: %d" % job_state.get("size", 0))
            metrics["backup_size"] = job_state.get("size", 0)

        next_run = job_state.get("next_schedule")
        if next_run == "disabled":
            state = "WARN"
            msg_parts.append("Schedule is currently disabled")
        elif next_run != None:
            expected_time_with_buffer = next_run + 60 * 2
            if now > expected_time_with_buffer:
                state = "CRIT"
            msg_parts.append("Next run: %d" % next_run)

    else:
        state = "UNKNOWN"
        msg_parts.append("Unknown job state: " + job_state_state)

    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}