def main(ctx, params):
    if params.get("_discover"):
        section_file = "/var/lib/yolo-agent/oracle_jobs"
        stat_result = ctx.stat(section_file)
        if stat_result == None or not stat_result.get("exists", False):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        content = ctx.file_read(section_file)
        lines = content.split("\n")
        out = []
        for line in lines:
            if not line.strip():
                continue
            parts = line.split("|")
            if len(parts) <= 2:
                continue
            if parts[1].startswith(" Debug "):
                continue
            if len(parts) >= 11:
                item = parts[0] + "." + parts[1] + "." + parts[2] + "." + parts[3]
            elif len(parts) == 10:
                item = parts[0] + "." + parts[1] + "." + parts[2]
            else:
                sp = line.split()
                if len(sp) >= 3:
                    item = sp[0] + "." + sp[1] + "." + sp[2]
                else:
                    continue
            out.append({"item": item, "params": {"consider_job_status": "ignore", "missinglog": 1, "status_missing_jobs": 2}, "metrics": ["duration"]})
        return {"changed": False, "msg": "discovered %d jobs" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item provided", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section_file = "/var/lib/yolo-agent/oracle_jobs"
    stat_result = ctx.stat(section_file)
    if stat_result == None or not stat_result.get("exists", False):
        return {"changed": False, "msg": "no data source", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(section_file)
    lines = content.split("\n")
    sid = ""
    dot_pos = item.find(".")
    if dot_pos > 0:
        sid = item[:dot_pos]
    else:
        sid = item

    data_found = False
    service_found = False
    job_state = ""
    job_enabled = ""
    job_runtime = ""
    job_nextrun = ""
    job_schedule = ""
    job_last_state = ""
    lineformat = -1
    job_pdb = ""
    job_owner = ""
    job_name = ""

    for line in lines:
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) <= 2:
            continue

        if parts[1].startswith(" Debug "):
            continue

        if parts[0] == sid:
            data_found = True

        if len(parts) == 11 and item.count(".") >= 3:
            items = item.split(".", 3)
            if len(items) < 4:
                continue
            itemsid, itempdb, itemowner, itemname = items
            lineformat = 3

            (
                sid,
                job_pdb,
                job_owner,
                job_name,
                job_state,
                job_runtime,
                _job_run_count,
                job_enabled,
                job_nextrun,
                job_schedule,
                job_last_state,
            ) = parts

            if itemname == job_name and itemowner == job_owner and itempdb == job_pdb and itemsid == sid:
                service_found = True
                break

        elif len(parts) == 10:
            items = item.split(".", 2)
            if len(items) < 3:
                continue
            itemsid, itemowner, itemname = items
            itempdb = ""
            lineformat = 2

            (
                sid,
                job_owner,
                job_name,
                job_state,
                job_runtime,
                _job_run_count,
                job_enabled,
                job_nextrun,
                job_schedule,
                job_last_state,
            ) = parts

            if itemname == job_name and itemowner == job_owner and itemsid == sid:
                service_found = True
                break

        elif len(parts) > 8:
            items = item.split(".", 1)
            if len(items) < 2:
                continue
            itemsid, itemname = items
            itempdb = ""
            itemowner = ""
            lineformat = 1

            job_name = parts[2]
            job_state = parts[3]
            job_runtime = parts[4]
            job_enabled = parts[6]
            job_nextrun = " ".join(parts[7:-3])
            job_schedule = parts[-2]
            job_last_state = parts[-1]

            if itemname == job_name and itemsid == sid:
                service_found = True
                break

    if not data_found:
        return {"changed": False, "msg": "Login not possible for check %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not service_found:
        missing_state = params.get("status_missing_jobs", params.get("missingjob", 2))
        return {"changed": False, "msg": "Job is missing",
                "data": {"state": "CRIT" if missing_state == 2 else ("WARN" if missing_state == 1 else "OK"),
                         "metrics": {}, "details": ""}}

    state = "OK"
    output_parts = []
    param_consider_job_status = params.get("consider_job_status", "ignore")

    txt = "Job-State: %s" % job_state
    if job_state == "BROKEN":
        txt += " (!!)"
        state = "CRIT"
    output_parts.append(txt)

    enabled_txt = "Yes" if job_enabled == "TRUE" else "No"
    txt = "Enabled: %s" % enabled_txt
    if job_enabled != "TRUE" and job_state != "RUNNING":
        if param_consider_job_status == "ignore":
            txt += " (ignored)"
        else:
            txt += " (!)"
            if state != "CRIT":
                state = "WARN"
    output_parts.append(txt)

    last_duration = 0
    if job_runtime != "" and job_runtime != "SCHEDULED":
        dur_str = job_runtime.split(".", 1)[0]
        if dur_str.isdigit():
            last_duration = int(dur_str)

    output_parts.append("Last Duration: %ds" % last_duration)

    if "run_duration" in params:
        warn_dur, crit_dur = params["run_duration"]
        output_parts.append(" (warn/crit at %ds/%ds)" % (warn_dur, crit_dur))
        if last_duration >= crit_dur:
            output_parts.append("(!!)")
            state = "CRIT"
        elif last_duration >= warn_dur:
            output_parts.append("(!)")
            if state != "CRIT":
                state = "WARN"

    metrics = {"duration": last_duration}

    if job_nextrun.startswith("01.01.70 00:00:00"):
        if job_schedule == "-" and job_state != "DISABLED":
            job_nextrun = "not scheduled (!)"
            if state != "CRIT" and state != "WARN":
                state = "WARN"
        else:
            job_nextrun = job_schedule
    output_parts.append("Next Run: %s" % job_nextrun)

    missinglog = params.get("missinglog", 1)

    if job_state == "RUNNING" and job_runtime == "" and job_last_state == "STOPPED":
        txt = "Job is running forever"
        output_parts.append(txt)
    elif job_last_state == "":
        txt = "no log information found"
        if missinglog == 0:
            txt += " (ignored)"
        elif missinglog == 1:
            txt += " (!)"
            if state != "CRIT" and state != "WARN":
                state = "WARN"
        elif missinglog == 2:
            txt += " (!!)"
            state = "CRIT"
        elif missinglog == 3:
            txt += " (?)"
            state = "UNKNOWN"
        output_parts.append(txt)
        if missinglog == 0:
            state = "OK"
        elif missinglog == 1:
            state = "WARN"
        elif missinglog == 2:
            state = "CRIT"
        elif missinglog == 3:
            state = "UNKNOWN"
    else:
        txt = "Last Run Status: %s" % job_last_state
        if job_enabled == "TRUE" and job_last_state != "SUCCEEDED":
            state = "CRIT"
        else:
            txt += " (ignored disabled Job)"
        output_parts.append(txt)

    if job_state == "DISABLED":
        if "status_disabled_jobs" in params:
            disabled_state = params["status_disabled_jobs"]
            if disabled_state == 0:
                state = "OK"
            elif disabled_state == 1:
                state = "WARN"
            elif disabled_state == 2:
                state = "CRIT"
            elif disabled_state == 3:
                state = "UNKNOWN"
        else:
            state = "CRIT"

    final_output = ", ".join(output_parts)
    return {"changed": False, "msg": final_output,
            "data": {"state": state, "metrics": metrics, "details": ""}}