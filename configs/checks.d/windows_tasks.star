def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cmd.exe", "/c", "schtasks.exe", "/query", "/fo", "LIST", "/v"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to list tasks: " + res.stderr,
                    "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        tasks = []
        current_task = {}
        for line in lines:
            stripped = line.strip()
            if not stripped:
                if current_task and "TaskName" in current_task:
                    tasks.append(current_task)
                current_task = {}
                continue
            if ":" in stripped:
                idx = stripped.find(":")
                key = stripped[:idx].strip()
                value = stripped[idx+1:].strip()
                if key == "TaskName":
                    if current_task and "TaskName" in current_task:
                        tasks.append(current_task)
                    current_task = {"TaskName": value}
                else:
                    current_task[key] = value
        if current_task and "TaskName" in current_task:
            tasks.append(current_task)

        out = []
        for t in tasks:
            name = t.get("TaskName", "")
            state = t.get("Scheduled Task State", "")
            # skip disabled tasks unless discover_disabled is set
            if params.get("discover_disabled", False) or state != "Disabled":
                out.append({"item": name, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d tasks" % len(out),
                "data": {"discovery": out}}

    # check mode: examine one item
    item = params.get("item", "")
    res = ctx.run(["cmd.exe", "/c", "schtasks.exe", "/query", "/fo", "LIST", "/v"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to list tasks: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    current_task = {}
    found_task = {}
    for line in lines:
        stripped = line.strip()
        if not stripped:
            if current_task and "TaskName" in current_task and current_task["TaskName"] == item:
                found_task = current_task
            current_task = {}
            continue
        if ":" in stripped:
            idx = stripped.find(":")
            key = stripped[:idx].strip()
            value = stripped[idx+1:].strip()
            if key == "TaskName":
                if current_task and "TaskName" in current_task:
                    if current_task["TaskName"] == item:
                        found_task = current_task
                current_task = {"TaskName": value}
            else:
                current_task[key] = value
    if current_task and "TaskName" in current_task and current_task["TaskName"] == item:
        found_task = current_task

    if not found_task:
        return {"changed": False, "msg": "Task not found on server",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # exit code mapping
    _MAP_EXIT_CODES = {
        "0x00000000": (0, "The task exited successfully"),
        "0x00041300": (0, "The task is ready to run at its next scheduled time."),
        "0x00041301": (0, "The task is currently running."),
        "0x00041302": (0, "The task will not run at the scheduled times because it has been disabled."),
        "0x00041303": (0, "The task has not yet run."),
        "0x00041304": (0, "There are no more runs scheduled for this task."),
        "0x00041305": (1, "One or more of the properties that are needed to run this task on a schedule have not been set."),
        "0x00041306": (0, "The last run of the task was terminated by the user."),
        "0x00041307": (1, "Either the task has no triggers or the existing triggers are disabled or not set."),
        "0x00041308": (1, "Event triggers do not have set run times."),
        "0x80041309": (1, "A task's trigger is not found."),
        "0x8004130a": (1, "One or more of the properties required to run this task have not been set."),
        "0x8004130b": (0, "There is no running instance of the task."),
        "0x8004130c": (2, "The Task Scheduler service is not installed on this computer."),
        "0x8004130d": (1, "The task object could not be opened."),
        "0x8004130e": (1, "The object is either an invalid task object or is not a task object."),
        "0x8004130f": (1, "No account information could be found in the Task Scheduler security database for the task indicated."),
        "0x80041310": (1, "Unable to establish existence of the account specified."),
        "0x80041311": (2, "Corruption was detected in the Task Scheduler security database; the database has been reset."),
        "0x80041312": (1, "Task Scheduler security services are available only on Windows NT."),
        "0x80041313": (1, "The task object version is either unsupported or invalid."),
        "0x80041314": (1, "The task has been configured with an unsupported combination of account settings and run time options."),
        "0x80041315": (1, "The Task Scheduler Service is not running."),
        "0x80041316": (1, "The task XML contains an unexpected node."),
        "0x80041317": (1, "The task XML contains an element or attribute from an unexpected namespace."),
        "0x80041318": (1, "The task XML contains a value which is incorrectly formatted or out of range."),
        "0x80041319": (1, "The task XML is missing a required element or attribute."),
        "0x8004131a": (1, "The task XML is malformed."),
        "0x0004131b": (1, "The task is registered, but not all specified triggers will start the task."),
        "0x0004131c": (1, "The task is registered, but may fail to start. Batch logon privilege needs to be enabled for the task principal."),
        "0x8004131d": (1, "The task XML contains too many nodes of the same type."),
        "0x8004131e": (1, "The task cannot be started after the trigger end boundary."),
        "0x8004131f": (0, "An instance of this task is already running."),
        "0x80041320": (1, "The task will not run because the user is not logged on."),
        "0x80041321": (1, "The task image is corrupt or has been tampered with."),
        "0x80041322": (1, "The Task Scheduler service is not available."),
        "0x80041323": (1, "The Task Scheduler service is too busy to handle your request. Please try again later."),
        "0x80041324": (1, "The Task Scheduler service attempted to run the task, but the task did not run due to one of the constraints in the task definition."),
        "0x00041325": (0, "The Task Scheduler service has asked the task to run."),
        "0x80041326": (0, "The task is disabled."),
        "0x80041327": (1, "The task has properties that are not compatible with earlier versions of Windows."),
        "0x80041328": (1, "The task settings do not allow the task to start on demand."),
    }

    # Build custom mapping from params
    custom_map = {}
    for entry in params.get("exit_code_to_state", []):
        code = entry.get("exit_code", "")
        st = entry.get("monitoring_state", 0)
        txt = entry.get("info_text", "")
        if code:
            custom_map[code] = (st, txt)

    map_codes = dict(_MAP_EXIT_CODES)
    map_codes.update(custom_map)

    # Get Last Result
    last_result_raw = found_task.get("Last Result", "0")
    last_result_int = int(last_result_raw) if last_result_raw.isdigit() or (last_result_raw.startswith("-") and last_result_raw[1:].isdigit()) else 0
    last_result_unsigned = last_result_int & 0xFFFFFFFF
    last_result_hex = "%x" % last_result_unsigned
    last_result_hex_full = "0x" + last_result_hex

    state_tuple = map_codes.get(last_result_hex_full, (2, None))
    state = state_tuple[0]
    state_txt = state_tuple[1]

    # Apply state_not_enabled
    state_not_enabled = params.get("state_not_enabled", 1)

    summary_parts = []
    if state_txt:
        summary_parts.append("%s (%s)" % (state_txt, last_result_hex_full))
    else:
        summary_parts.append("Got exit code %s" % last_result_hex_full)

    # Task enabled status
    task_state = found_task.get("Scheduled Task State", "")
    if task_state != "Enabled":
        summary_parts.append("Task not enabled")
        if state == 0:  # only downgrade if primary state is OK
            state = state_not_enabled

    # Additional info
    additional = []
    for key, title in [("Last Run Time", "Last run time"), ("Next Run Time", "Next run time")]:
        if key in found_task:
            additional.append("%s: %s" % (title, found_task[key]))

    msg = ", ".join(summary_parts)
    if additional:
        msg += " | " + ", ".join(additional)

    return {"changed": False, "msg": msg,
            "data": {"state": "OK" if state == 0 else ("WARN" if state == 1 else ("CRIT" if state == 2 else "UNKNOWN")),
                     "metrics": {"exit_code": last_result_int},
                     "details": ""}}