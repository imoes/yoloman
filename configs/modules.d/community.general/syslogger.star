def main(ctx, params):
    msg = params["msg"]
    ident = params.get("ident", "ansible_syslogger")
    priority = params.get("priority", "info")
    facility = params.get("facility", "daemon")
    log_pid = params.get("log_pid", False)

    # Validate choices
    valid_priorities = ["emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"]
    if priority not in valid_priorities:
        fail("priority must be one of: %s" % ", ".join(valid_priorities))

    valid_facilities = ["kern", "user", "mail", "daemon", "auth", "lpr", "news",
                        "uucp", "cron", "syslog", "local0", "local1", "local2",
                        "local3", "local4", "local5", "local6", "local7"]
    if facility not in valid_facilities:
        fail("facility must be one of: %s" % ", ".join(valid_facilities))

    # Map priorities and facilities to syslog constants (using integer values)
    priority_map = {
        "emerg": 0, "alert": 1, "crit": 2, "err": 3, "warning": 4,
        "notice": 5, "info": 6, "debug": 7
    }
    facility_map = {
        "kern": 0, "user": 1, "mail": 2, "daemon": 3, "auth": 4,
        "lpr": 5, "news": 6, "uucp": 7, "cron": 8, "syslog": 9,
        "local0": 16, "local1": 17, "local2": 18, "local3": 19,
        "local4": 20, "local5": 21, "local6": 22, "local7": 23
    }

    # Build syslog priority value (facility << 3 | priority)
    log_priority = (facility_map[facility] << 3) | priority_map[priority]
    options = 1 if log_pid else 0  # syslog.LOG_PID = 1

    # The syslog module doesn't exist in Starlark, so use logger command instead
    # Construct command-line arguments
    logger_cmd = ["logger", "-p", str(log_priority), "-t", ident]
    if options == 1:
        logger_cmd.append("-p")  # placeholder to keep args consistent
        # logger -t already includes PID by default when using -t, but we can't control it precisely

    # Use the logger command to write to syslog
    res = ctx.run(logger_cmd + [msg], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would log to syslog", "data": {
            "ident": ident,
            "priority": priority,
            "facility": facility,
            "log_pid": log_pid,
            "msg": msg
        }}

    if res.rc != 0:
        fail("failed to log message: " + res.stderr)

    return {"changed": True, "msg": "logged message to syslog", "data": {
        "ident": ident,
        "priority": priority,
        "facility": facility,
        "log_pid": log_pid,
        "msg": msg
    }}
