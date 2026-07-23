# Constants
_DATETIME_FMT = "%Y-%m-%d %H:%M:%S"

_OUTCOME_TRANSLATION = {
    "": "N/A",
    "0": "Fail",
    "1": "Succeed",
    "2": "Retry",
    "3": "Cancel",
    "4": "In progress",
    "5": "Unknown",
}

_STATUS_MAPPING = {
    "Fail": "CRIT",
    "Succeed": "OK",
    "Retry": "OK",
    "Cancel": "OK",
    "In progress": "OK",
    "Unknown": "UNKNOWN",
}

_DEFAULTS = {
    "consider_job_status": "ignore",
    "status_disabled_jobs": 0,
    "status_disabled_schedule": 0,
    "status_missing_jobs": 2,
}


def _calculate_seconds(raw_duration):
    """Return the number of seconds from a string in HHMMSS format."""
    if raw_duration == None or raw_duration == "":
        return None
    length = len(raw_duration)
    if length <= 2:
        if raw_duration.isdigit():
            return float(raw_duration)
        return None
    if length <= 4:
        if not raw_duration[-2:].isdigit():
            return None
        raw_seconds = float(raw_duration[-2:])
        if not raw_duration[:-2].isdigit():
            return None
        raw_minutes = float(raw_duration[:-2])
        return raw_seconds + raw_minutes * 60
    if not raw_duration[-2:].isdigit():
        return None
    raw_seconds = float(raw_duration[-2:])
    if not raw_duration[-4:-2].isdigit():
        return None
    raw_minutes = float(raw_duration[-4:-2])
    if not raw_duration[:-4].isdigit():
        return None
    raw_hours = float(raw_duration[:-4])
    return raw_seconds + raw_minutes * 60 + raw_hours * 3600


def _format_to_datetime(raw_date, raw_time):
    """Return a valid datetime from date and time strings in YYYYMMDD and HHMMSS formats."""
    if raw_date == "0" or raw_date == "":
        return "N/A"
    if raw_time == None or raw_time == "":
        raw_time = "0"
    padded_time = raw_time.zfill(6)
    # Format: YYYYMMDD HHMMSS
    date_part = raw_date
    time_part = padded_time
    
    # Validate basic structure
    if len(date_part) < 8 or len(time_part) < 6:
        return "N/A"
    
    year = int(date_part[0:4]) if date_part[0:4].isdigit() else 0
    month = int(date_part[4:6]) if date_part[4:6].isdigit() else 0
    day = int(date_part[6:8]) if date_part[6:8].isdigit() else 0
    hour = int(time_part[0:2]) if time_part[0:2].isdigit() else 0
    minute = int(time_part[2:4]) if time_part[2:4].isdigit() else 0
    second = int(time_part[4:6]) if time_part[4:6].isdigit() else 0
    
    # Simple validation
    if not ((1 <= month) and (month <= 12) and (1 <= day) and (day <= 31) and (0 <= hour) and (hour <= 23) and (0 <= minute) and (minute <= 59) and (0 <= second) and (second <= 59)):
        return "N/A"
    
    return "%d-%d-%d %d:%d:%d" % (year, month, day, hour, minute, second)


def _parse_jobs(lines):
    """Parse mssql_jobs agent section lines into a dict of job specs."""
    section = {}
    current_instance = None

    for line in lines:
        if len(line) == 1 and line[0].strip() == "":
            continue
        # Instance header (single column)
        if len(line) == 1:
            current_instance = line[0]
            continue

        # Skip malformed lines
        if len(line) < 12:
            continue

        job = {
            "job_id": line[0],
            "job_name": line[1],
            "job_enabled": line[2],
            "next_run_date": line[3],
            "next_run_time": line[4],
            "last_run_outcome": line[5],
            "last_outcome_message": line[6],
            "last_run_date": line[7],
            "last_run_time": line[8],
            "last_run_duration": line[9],
            "schedule_enabled": line[10],
            "server_current_time": line[11],
        }

        last_run_outcome = _OUTCOME_TRANSLATION.get(job["last_run_outcome"], "Unknown")
        job_name = job["job_name"] if job["job_name"] else job["job_id"]
        key = (job_name + " - " + current_instance) if current_instance else job_name

        if key not in section:
            section[key] = {
                "last_run_duration": _calculate_seconds(job["last_run_duration"]),
                "last_run_outcome": last_run_outcome,
                "last_run_datetime": _format_to_datetime(job["last_run_date"], job["last_run_time"]),
                "enabled": job["job_enabled"] not in ["", "0"],
                "schedule_enabled": job["schedule_enabled"] not in ["", "0"],
                "next_run_datetime": _format_to_datetime(job["next_run_date"], job["next_run_time"]),
                "last_outcome_message": job["last_outcome_message"],
                "state": _STATUS_MAPPING.get(last_run_outcome, "UNKNOWN"),
            }

    return section


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: run mssql-cli command to get job data
        # Checkmk agent section mssql_jobs is typically populated by a SQL query via mssql-cli
        # We replicate the same query using mssql-cli
        server = params.get("server", ".")
        database = params.get("database", "master")
        user = params.get("username")
        password = params.get("password")
        
        # Build connection string parts
        conn_args = []
        if user:
            conn_args.append("-U")
            conn_args.append(user)
        if password:
            conn_args.append("-P")
            conn_args.append(password)
        conn_args.append("-S")
        conn_args.append(server)
        conn_args.append("-d")
        conn_args.append(database)
        
        # Query to match Checkmk's logic
        query = """
        SELECT 
            j.name AS job_name,
            j.enabled AS job_enabled,
            js.next_run_date,
            js.next_run_time,
            js.last_run_outcome,
            js.last_outcome_message,
            js.last_run_date,
            js.last_run_time,
            js.last_run_duration,
            s.enabled AS schedule_enabled,
            GETDATE() AS server_current_time
        FROM msdb.dbo.sysjobs j
        LEFT JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
        LEFT JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
        WHERE j.enabled = 1 OR j.enabled = 0
        ORDER BY j.name
        """
        
        # Use mssql-cli to run query in column mode with tab separator
        res = ctx.run([
            "mssql-cli",
            "-Q",
            query,
            "--output-format",
            "tsv",
            "-W",
            "-H",
            "mssql_jobs"
        ] + conn_args, mutates=False)

        # If query failed with syntax error or connection issue, return empty
        if res.rc != 0 or not res.stdout:
            # Try alternative approach: use sqlcmd instead if available
            res2 = ctx.run([
                "sqlcmd",
                "-Q", query,
                "-W",
                "-h", "-1",
                "-s", "\t"
            ] + conn_args, mutates=False)
            if res2.rc == 0 and res2.stdout:
                res = res2
            else:
                # Return empty discovery if all fail (job not found scenario)
                pass

        lines = []
        current_instance = None
        for line in res.stdout.splitlines():
            if not line:
                continue
            # Split by tab
            fields = line.split("\t")
            if len(fields) == 1 and current_instance == None:
                # Could be instance name header
                current_instance = fields[0]
                continue
            lines.append(fields)

        # Parse into section format
        section = _parse_jobs(lines)

        # Build discovery result
        items = []
        for job_name in section:
            if job_name:
                items.append({
                    "item": job_name,
                    "params": {
                        "consider_job_status": _DEFAULTS["consider_job_status"],
                        "status_disabled_jobs": _DEFAULTS["status_disabled_jobs"],
                        "status_disabled_schedule": _DEFAULTS["status_disabled_schedule"],
                        "status_missing_jobs": _DEFAULTS["status_missing_jobs"],
                    },
                    "metrics": ["database_job_duration"]
                })

        return {
            "changed": False,
            "msg": "discovered %d jobs" % len(items),
            "data": {"discovery": items}
        }

    # Normal check mode
    item = params.get("item", "")
    server = params.get("server", ".")
    database = params.get("database", "master")
    user = params.get("username")
    password = params.get("password")
    
    conn_args = []
    if user:
        conn_args.append("-U")
        conn_args.append(user)
    if password:
        conn_args.append("-P")
        conn_args.append(password)
    conn_args.append("-S")
    conn_args.append(server)
    conn_args.append("-d")
    conn_args.append(database)
    
    # Escape single quotes in item name
    escaped_item = item.replace("'", "''")
    query = """
    SELECT 
        j.name AS job_name,
        j.enabled AS job_enabled,
        js.next_run_date,
        js.next_run_time,
        js.last_run_outcome,
        js.last_outcome_message,
        js.last_run_date,
        js.last_run_time,
        js.last_run_duration,
        s.enabled AS schedule_enabled,
        GETDATE() AS server_current_time
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
    LEFT JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
    WHERE j.name = '%s'
    """ % escaped_item

    res = ctx.run([
        "mssql-cli",
        "-Q", query,
        "--output-format", "tsv",
        "-W",
        "-H", "mssql_jobs"
    ] + conn_args, mutates=False)

    # Fallback to sqlcmd if mssql-cli fails
    if res.rc != 0 or not res.stdout:
        res2 = ctx.run([
            "sqlcmd",
            "-Q", query,
            "-W",
            "-h", "-1",
            "-s", "\t"
        ] + conn_args, mutates=False)
        if res2.rc == 0 and res2.stdout:
            res = res2
        else:
            # Job not found scenario
            status_missing_jobs = params.get("status_missing_jobs", _DEFAULTS["status_missing_jobs"])
            state = "CRIT" if status_missing_jobs == 2 else ("WARN" if status_missing_jobs == 1 else "OK")
            return {
                "changed": False,
                "msg": "Job not found",
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": ""
                }
            }

    # Parse output
    lines = []
    for line in res.stdout.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) >= 11:
            lines.append(fields)
    
    if not lines:
        status_missing_jobs = params.get("status_missing_jobs", _DEFAULTS["status_missing_jobs"])
        state = "CRIT" if status_missing_jobs == 2 else ("WARN" if status_missing_jobs == 1 else "OK")
        return {
            "changed": False,
            "msg": "Job not found",
            "data": {
                "state": state,
                "metrics": {},
                "details": ""
            }
        }

    # Use first row for item
    line = lines[0]
    if len(line) < 11:
        status_missing_jobs = params.get("status_missing_jobs", _DEFAULTS["status_missing_jobs"])
        state = "CRIT" if status_missing_jobs == 2 else ("WARN" if status_missing_jobs == 1 else "OK")
        return {
            "changed": False,
            "msg": "Job not found",
            "data": {
                "state": state,
                "metrics": {},
                "details": ""
            }
        }

    job = {
        "job_name": line[0],
        "job_enabled": line[1],
        "next_run_date": line[2],
        "next_run_time": line[3],
        "last_run_outcome": line[4],
        "last_outcome_message": line[5],
        "last_run_date": line[6],
        "last_run_time": line[7],
        "last_run_duration": line[8],
        "schedule_enabled": line[9],
        "server_current_time": line[10],
    }

    last_run_outcome = _OUTCOME_TRANSLATION.get(job["last_run_outcome"], "Unknown")
    job_enabled = job["job_enabled"] not in ["", "0"]
    schedule_enabled = job["schedule_enabled"] not in ["", "0"]
    last_run_datetime = _format_to_datetime(job["last_run_date"], job["last_run_time"])
    next_run_datetime = _format_to_datetime(job["next_run_date"], job["next_run_time"])
    last_run_duration = _calculate_seconds(job["last_run_duration"])
    state = _STATUS_MAPPING.get(last_run_outcome, "UNKNOWN")

    # Determine final state based on params
    consider_job_status = params.get("consider_job_status", _DEFAULTS["consider_job_status"])
    if consider_job_status == "ignore":
        db_status = "OK"
    elif consider_job_status == "consider":
        db_status = state
    elif consider_job_status == "consider_if_enabled":
        db_status = state if job_enabled else "OK"
    else:
        db_status = "OK"

    # Check job disabled status
    if not job_enabled:
        status_disabled_jobs = params.get("status_disabled_jobs", _DEFAULTS["status_disabled_jobs"])
        if status_disabled_jobs == 2:
            db_status = "CRIT"
        elif status_disabled_jobs == 1:
            db_status = "WARN"

    # Check schedule disabled status
    if not schedule_enabled:
        status_disabled_schedule = params.get("status_disabled_schedule", _DEFAULTS["status_disabled_schedule"])
        if status_disabled_schedule == 2:
            db_status = "CRIT"
        elif status_disabled_schedule == 1:
            db_status = "WARN"

    # Build summary message
    msg_parts = []
    if last_run_duration != None:
        seconds = int(last_run_duration)
        hours = seconds // 3600
        minutes = (seconds % 3600) // 60
        secs = seconds % 60
        duration_str = "%dh %dm %ds" % (hours, minutes, secs) if hours > 0 else "%dm %ds" % (minutes, secs)
        msg_parts.append("Last duration: %s" % duration_str)
    msg_parts.append("MSSQL status: %s" % last_run_outcome)
    msg_parts.append("Last run: %s" % last_run_datetime)
    if job_enabled:
        if schedule_enabled:
            msg_parts.append("Next run: %s" % next_run_datetime)
        else:
            msg_parts.append("Schedule is disabled")
    else:
        msg_parts.append("Job is disabled")

    # Metrics
    metrics = {}
    if last_run_duration != None:
        metrics["database_job_duration"] = last_run_duration

    return {
        "changed": False,
        "msg": "; ".join(msg_parts),
        "data": {
            "state": db_status,
            "metrics": metrics,
            "details": ""
        }
    }