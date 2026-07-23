# Maps for status and error states (constants at module top level)
_STATUS_MAP = {
    1: "Other",
    2: "Unknown",
    3: "Idle",
    4: "Printing",
    5: "Warming Up",
    6: "Stopped Printing",
    7: "Offline",
}

_ERROR_MAP = {
    0: "Unknown",
    1: "Other",
    2: "No Error",
    3: "Low Paper",
    4: "No Paper",
    5: "Low Toner",
    6: "No Toner",
    7: "Door Open",
    8: "Jammed",
    9: "Offline",
    10: "Service Requested",
    11: "Output Bin Full",
}


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        raw = ctx.agent_section("win_printers")
        if raw == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        parsed = {}
        for line in raw.split("\n"):
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 4:
                continue
            # Guard parsing with.isdigit() checks
            jobs_str = parts[-3]
            status_str = parts[-2]
            error_str = parts[-1]
            if not (jobs_str.isdigit() and status_str.isdigit() and error_str.isdigit()):
                continue
            jobs = int(jobs_str)
            status = int(status_str)
            error = int(error_str)
            name = " ".join(parts[:-3])
            parsed[name] = {"jobs": jobs, "status": status, "error": error}

        out = []
        for name, q in parsed.items():
            # Do not discover offline printers (error == 9)
            if q["error"] != 9:
                out.append({"item": name, "params": {
                    "warn_states": [8, 11],
                    "crit_states": [9, 10],
                }, "metrics": ["jobs"]})

        return {"changed": False, "msg": "discovered %d printers" % len(out),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    if item == None:
        item = ""

    # Fetch raw section again for check
    raw = ctx.agent_section("win_printers")
    if raw == None:
        return {"changed": False, "msg": "section not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = {}
    for line in raw.split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        # Guard parsing with.isdigit() checks
        jobs_str = parts[-3]
        status_str = parts[-2]
        error_str = parts[-1]
        if not (jobs_str.isdigit() and status_str.isdigit() and error_str.isdigit()):
            continue
        jobs = int(jobs_str)
        status = int(status_str)
        error = int(error_str)
        name = " ".join(parts[:-3])
        parsed[name] = {"jobs": jobs, "status": status, "error": error}

    queue = parsed.get(item)
    if queue == None:
        return {"changed": False, "msg": "printer not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    jobs = queue["jobs"]
    status_code = queue["status"]
    error_code = queue["error"]

    # Build state and message
    state = "OK"
    msg_parts = []

    # Jobs check (levels)
    levels = params.get("levels")
    if levels != None:
        warn = levels.get("warn") if type(levels) == "dict" else None
        crit = levels.get("crit") if type(levels) == "dict" else None
        # Upper levels: warn/crit thresholds (jobs >= threshold -> WARN/CRIT)
        # Default is no thresholds, so OK
        if crit != None and jobs >= crit:
            state = "CRIT"
            msg_parts.append("Current jobs: %d (crit > %d)" % (jobs, crit))
        elif warn != None and jobs >= warn:
            if state == "OK":
                state = "WARN"
            msg_parts.append("Current jobs: %d (warn > %d)" % (jobs, warn))
        else:
            msg_parts.append("Current jobs: %d" % jobs)
    else:
        msg_parts.append("Current jobs: %d" % jobs)

    # Status
    status_name = _STATUS_MAP.get(status_code, "Unknown(%d)" % status_code)
    msg_parts.append("State: " + status_name)

    # Error state
    warn_states = params.get("warn_states", [8, 11])
    crit_states = params.get("crit_states", [9, 10])
    error_name = _ERROR_MAP.get(error_code, "Unknown(%d)" % error_code)

    if error_code in crit_states:
        state = "CRIT"
        msg_parts.append("Error state: " + error_name)
    elif error_code in warn_states:
        if state == "OK":
            state = "WARN"
        msg_parts.append("Error state: " + error_name)

    msg = ", ".join(msg_parts)
    metrics = {"jobs": jobs}

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
