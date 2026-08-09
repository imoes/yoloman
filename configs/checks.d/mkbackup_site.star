def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mkbackup", "--list"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to run mkbackup --list",
                    "data": {"discovery": []}}

        # Parse mkbackup list output (JSON per line)
        lines = res.stdout.splitlines()
        found_items = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            data = json.decode(line) if line else None
            if data != None and type(data) == "dict":
                site_id = data.get("site")
                job_id = data.get("job")
                if site_id != None and job_id != None:
                    item = site_id + " backup " + job_id
                    params_suggested = {}
                    metrics = ["backup_duration", "backup_avgspeed"]
                    if "size" in data:
                        metrics.append("backup_size")
                    found_items.append({"item": item, "params": params_suggested, "metrics": metrics})

        return {"changed": False, "msg": "discovered %d backup items" % len(found_items),
                "data": {"discovery": found_items}}

    # Normal check mode
    item = params.get("item", "")
    if item == None:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split(" backup ")
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    site_id = parts[0]
    job_id = parts[1]

    # Query backup details
    res = ctx.run(["mkbackup", "--show-job", site_id, job_id], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "job not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not res.stdout:
        return {"changed": False, "msg": "no output from mkbackup",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    job_data = json.decode(res.stdout)
    if type(job_data) != "dict" or job_data.get("state") == None:
        return {"changed": False, "msg": "job data malformed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_map = {
        "started": "OK",
        "running": "OK",
        "finished": "OK" if job_data.get("success") else "CRIT",
        "stopped": "WARN",
        "canceled": "WARN",
    }
    state_str = state_map.get(job_data.get("state", ""), "UNKNOWN")

    if job_data["state"] in ["started", "running"]:
        now_res = ctx.run(["date", "+%s"], mutates=False)
        now = 0
        if now_res.rc == 0 and now_res.stdout.strip() != "":
            now = int(now_res.stdout.strip())
        duration = now - job_data["started"]
        msg = "The job is running for " + str(int(duration)) + " seconds since " + str(int(job_data["started"]))

    elif job_data["state"] == "finished":
        if not job_data.get("success"):
            msg = "Backup failed"
        else:
            msg = "Backup completed"
        duration = job_data["finished"] - job_data["started"]
        msg = msg + "; it was running for " + str(int(duration)) + " seconds from " + str(int(job_data["started"])) + " to " + str(int(job_data["finished"]))
        if "size" in job_data and job_data.get("success"):
            msg = msg + "; Size: " + str(job_data["size"]) + " bytes"

    else:
        msg = "Job state: " + job_data["state"]
        duration = 0.0

    # Next run check
    next_run = job_data.get("next_schedule")
    if next_run == "disabled":
        msg = msg + "; Schedule is currently disabled"
    elif next_run != None and str(next_run) != "":
        now_res = ctx.run(["date", "+%s"], mutates=False)
        now = 0
        if now_res.rc == 0 and now_res.stdout.strip() != "":
            now = int(now_res.stdout.strip())
        expected_buffer = int(float(str(next_run))) + 120
        if now > expected_buffer:
            state_str = "CRIT"
        msg = msg + "; Next run: " + str(int(float(str(next_run))))

    metrics = {
        "backup_duration": float(duration),
        "backup_avgspeed": float(job_data.get("bytes_per_second", 0.0)),
    }
    if "size" in job_data and job_data.get("success"):
        metrics["backup_size"] = float(job_data["size"])

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": "",
        },
    }
