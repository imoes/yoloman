def _job_parse_real_time(s):
    parts = s.split(":")
    min_sec, hour_sec = 0, 0
    if len(parts) == 3:
        hour_sec = int(parts[0]) * 60 * 60
    if len(parts) >= 2:
        min_sec = int(parts[-2]) * 60
    return float(parts[-1]) + min_sec + hour_sec

def _job_parse_metrics(name, value):
    translation = {
        "real": "real_time",
        "user": "user_time",
        "sys": "system_time",
        "Real": "real_time",
        "User": "user_time",
        "System": "system_time",
    }
    name = translation.get(name, name)
    value = value.replace(",", ".")
    if name == "real_time":
        return name, _job_parse_real_time(value)
    if name in ("user_time", "system_time"):
        return name, float(value)
    if name in ("max_res_kbytes", "avg_mem_kbytes"):
        return name.replace("kbytes", "bytes"), int(value) * 1000
    return name, int(value)

def _parse_job(string_table):
    parsed = {}
    pseudo_running_jobs = {}
    job = {}
    running = False

    idx = 0
    while idx < len(string_table):
        line = string_table[idx]
        if len(line) > 0 and line[0] == "==>" and len(line) > 0 and line[-1] == "<==":
            # Extract jobname from "==> JobName running <==" pattern
            jobname = " ".join(line[1:-1])
            running_state = "not_running"

            if not jobname.endswith("running"):
                jobname = jobname
                running_state = "not_running"
            else:
                jobname = jobname.rsplit(".", 1)[0]
                # Check if pseudo-running: no start_time or wrong structure
                if idx + 1 >= len(string_table) or string_table[idx + 1][0] != "start_time":
                    running_state = "pseudo_running"
                elif idx + 2 < len(string_table) and string_table[idx + 2][0] != "==>" and len(string_table[idx + 2]) > 0:
                    running_state = "pseudo_running"

            job_stats = {"running": running_state == "running", "metrics": {}}

            if running_state == "pseudo_running":
                existing = pseudo_running_jobs.get(jobname, {})
                if len(existing) == 0:
                    pseudo_running_jobs[jobname] = job_stats
                job = pseudo_running_jobs.get(jobname, {})
                idx = idx + 1
                continue

            # Normal job parsing
            existing = parsed.get(jobname, {})
            if len(existing) > 0:
                if job_stats.get("running") == True:
                    parsed[jobname]["running"] = True
                job = parsed.get(jobname, {})
            else:
                parsed[jobname] = job_stats
                job = parsed.get(jobname, {})

            idx = idx + 1
            continue

        if len(line) == 2 and job != {}:
            name, value = line[0], line[1]
            metric_name, metric_value = _job_parse_metrics(name, value)
            if running:
                job.setdefault("running_start_time", []).append(int(metric_value))
            elif metric_name == "exit_code":
                job["exit_code"] = int(metric_value)
            elif metric_name == "start_time":
                job["start_time"] = metric_value
            else:
                job["metrics"][metric_name] = metric_value

        idx = idx + 1

    # Handle pseudo-running jobs (use newer data if present)
    for jobname, pseudo_job in pseudo_running_jobs.items():
        start_time = pseudo_job.get("start_time", -1)
        existing_start = parsed.get(jobname, {}).get("start_time", 0)
        if start_time > existing_start:
            parsed[jobname] = pseudo_job

    return parsed

def _get_current_time(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0 and len(res.stdout) > 0:
        return int(res.stdout.strip())
    return 0

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/tmp/mk-job"], mutates=False)
        # Fallback if file doesn't exist
        if res.rc != 0 or len(res.stdout) == 0:
            return {"changed": False, "msg": "discovered 0 jobs", "data": {"discovery": []}}
        
        # Parse agent output manually (no Python stdlib)
        lines = res.stdout.split("\n")
        string_table = []
        for line in lines:
            stripped = line.strip()
            if len(stripped) == 0:
                continue
            # Split into tokens using simple space-based parsing
            tokens = stripped.split()
            if len(tokens) >= 1 and tokens[0].startswith("==>") and tokens[-1].endswith("<=="):
                string_table.append(tokens)
            elif len(tokens) == 2:
                string_table.append(tokens)
            elif len(tokens) >= 1:
                # Handle section headers and other lines
                string_table.append(tokens)

        section = _parse_job(string_table)
        discovery = []
        for jobname in section.keys():
            discovery.append({"item": jobname, "params": {}, "metrics": ["real_time", "job_age"]})
        return {"changed": False, "msg": "discovered %d jobs" % len(discovery), "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/tmp/mk-job"], mutates=False)
    
    # Fallback if file doesn't exist or command failed
    if res.rc != 0 or len(res.stdout) == 0:
        return {"changed": False, "msg": "no job data available", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse agent output manually
    lines = res.stdout.split("\n")
    string_table = []
    for line in lines:
        stripped = line.strip()
        if len(stripped) == 0:
            continue
        tokens = stripped.split()
        if len(tokens) >= 1 and tokens[0].startswith("==>") and tokens[-1].endswith("<=="):
            string_table.append(tokens)
        elif len(tokens) == 2:
            string_table.append(tokens)
        elif len(tokens) >= 1:
            string_table.append(tokens)

    section = _parse_job(string_table)
    job = section.get(item)
    
    if job == None:
        return {"changed": False, "msg": "no such job: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get exit code state
    exit_code = job.get("exit_code")
    if exit_code == None:
        return {"changed": False, "msg": "Got incomplete information for this job",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state from exit code (0 = OK)
    state = "OK" if exit_code == 0 else "CRIT"
    msg_parts = ["Latest exit code: %d" % exit_code]
    
    # Process metrics
    metrics = {}
    job_metrics = job.get("metrics", {})
    
    # Real time
    if job_metrics.get("real_time") != None:
        real_time = job_metrics["real_time"]
        metrics["real_time"] = real_time
        msg_parts.append("Real time: %f s" % real_time)
    
    # Job age calculation
    now = _get_current_time(ctx)
    if job.get("running_start_time") != None:
        start_times = job["running_start_time"]
        used_start_time = max(start_times)
        count = len(start_times)
        msg_parts.append("%d job%s currently running" % (count, " is" if count == 1 else "s are"))
    elif job.get("start_time") != None:
        used_start_time = job["start_time"]
    else:
        used_start_time = now  # Avoid negative age
    
    age = now - float(used_start_time)
    if age >= 0:
        metrics["job_age"] = age
        msg_parts.append("Job age: %f s" % age)
    else:
        msg_parts.append("Job age appears to be %f s in the future (check your system time)" % -age)
    
    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}
