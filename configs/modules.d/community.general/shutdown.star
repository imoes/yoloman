def main(ctx, params):
    delay = params.get("delay", 0)
    msg = params.get("msg", "Shut down initiated by Ansible")
    search_paths = params.get("search_paths", ["/sbin", "/usr/sbin", "/usr/local/sbin"])

    # Find shutdown command
    shutdown_cmd = None
    for path in search_paths:
        full_path = path + "/shutdown"
        if ctx.file_exists(full_path):
            shutdown_cmd = full_path
            break

    facts = ctx.facts()
    os_family = facts.get("os_family", "")

    # Determine delay argument format based on OS
    if shutdown_cmd:
        # Use shutdown command
        if os_family in ["debian", "redhat", "openbsd"]:
            # Convert seconds to minutes (rounded down), min 0
            delay_minutes = max(0, int(delay) // 60)
            if delay_minutes == 0 and delay > 0 and delay < 60:
                delay_minutes = 0
            argv = [shutdown_cmd, "-" + str(delay_minutes), msg]
        elif os_family in ["solaris", "freebsd"]:
            argv = [shutdown_cmd, "-" + str(delay), msg]
        else:
            # Default to minutes for unknown families
            delay_minutes = max(0, int(delay) // 60)
            argv = [shutdown_cmd, "-" + str(delay_minutes), msg]
    else:
        # Fallback to systemctl shutdown
        argv = ["systemctl", "shutdown", msg]

    # In check_mode, just predict the change without running
    if ctx.check_mode:
        return {"changed": True, "msg": "would shutdown the system", "shutdown": True}

    # Execute shutdown command
    res = ctx.run(argv, mutates=True)
    # Note: shutdown commands typically exit immediately but spawn background process
    # The runtime may still return non-zero if the command was rejected or not found
    if res.rc != 0 and res.rc != 100:  # 100 is sometimes used by shutdown as success
        fail("shutdown command failed: " + res.stderr)

    return {"changed": True, "msg": "shutdown initiated", "shutdown": True}
