def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        res = ctx.run(["cmk", "--run-plugin", "veeam_jobs"], mutates=False)
        if res.rc != 0:
            # Agent plugin not available or failed — no jobs discovered
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Parse JSON output from the veeam_jobs plugin
        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)

        # data is a list of dicts: [{"name": "...", "type": "...", ...}, ...]
        items = []
        for entry in data:
            name = entry.get("name")
            if name == None:
                continue
            items.append({
                "item": name,
                "params": {},  # no parameters needed for this check
                "metrics": []
            })

        return {"changed": False, "msg": "discovered %d jobs" % len(items),
                "data": {"discovery": items}}

    # === CHECK MODE ===
    item = params.get("item", "")
    if item == None:
        item = ""

    res = ctx.run(["cmk", "--run-plugin", "veeam_jobs"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "VEEAM job data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not res.stdout:
        return {"changed": False, "msg": "VEEAM job data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)

    # Find job with matching name
    job = None
    for entry in data:
        if entry.get("name") == item:
            job = entry
            break

    if job == None:
        return {"changed": False, "msg": "VEEAM job not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract fields with defaults for missing keys
    last_state = job.get("last_state", "")
    last_result = job.get("last_result", "")
    type_ = job.get("type", "")
    creation_time = job.get("creation_time", "")
    end_time = job.get("end_time", "")

    # Determine state per Checkmk logic
    if last_result == "None":
        if last_state in ["Starting", "Working", "Postprocessing"]:
            # Still running — skip for now
            return {"changed": False, "msg": "Data not present at the moment",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if last_state == "Idle" and type_ == "BackupSync":
            state = "OK"
        else:
            state = "UNKNOWN"
    elif last_result == "Success":
        state = "OK"
    elif last_result == "Failed":
        state = "CRIT"
    elif last_result == "Warning":
        state = "WARN"
    else:
        state = "UNKNOWN"

    # Build summary message
    msg_parts = ["State: " + last_state, "Result: " + last_result]
    msg = ", ".join(msg_parts)
    details_parts = []
    if creation_time != "":
        details_parts.append("Creation time: " + creation_time)
    if end_time != "":
        details_parts.append("End time: " + end_time)
    details_parts.append("Type: " + type_)
    details = "\n".join(details_parts)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": details}}
