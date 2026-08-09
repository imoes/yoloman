def main(ctx, params):
    service = params["name"]
    state = params.get("state")
    enabled = params.get("enabled")
    pattern = params.get("pattern")

    init_script = "/etc/init.d/" + service

    if not ctx.file_exists(init_script):
        fail("service %s does not exist" % service)

    result = {"changed": False, "name": service}

    # Handle enabled state
    if enabled != None:
        res = ctx.run([init_script, "enabled"])
        currently_enabled = res.rc == 0
        result["enabled"] = currently_enabled

        if currently_enabled != enabled:
            result["changed"] = True
            action = "enable" if enabled else "disable"
            if not ctx.check_mode:
                run_res = ctx.run([init_script, action], mutates=True)
                if run_res.rc != 0 or (not run_res.skipped and ctx.stat(init_script) != None and is_enabled(ctx, init_script) != enabled):
                    fail("Unable to %s service %s" % (action, service))
            result["enabled"] = not currently_enabled

    # Handle service state (started/stopped/restarted/reloaded)
    if state != None:
        running = False

        if pattern != None:
            ps_res = ctx.run(["ps", "w"], mutates=False)
            if ps_res.rc == 0:
                lines = ps_res.stdout.split("\n") if ps_res.stdout else []
                for line in lines:
                    if pattern in line and "pattern=" not in line:
                        running = True
                        break
        else:
            res = ctx.run([init_script, "running"], mutates=False)
            running = res.rc == 0

        result["state"] = state

        action = None
        if state == "started" and not running:
            action = "start"
            result["changed"] = True
        elif state == "stopped" and running:
            action = "stop"
            result["changed"] = True
        elif state in ("restarted", "reloaded"):
            action = state[:-2]
            result["state"] = "started"
            result["changed"] = True

        if action != None:
            if not ctx.check_mode:
                run_res = ctx.run([init_script, action], mutates=True)
                if run_res.rc != 0 and not run_res.skipped:
                    fail("Unable to %s service %s" % (action, service))

    return result

def is_enabled(ctx, init_script):
    res = ctx.run([init_script, "enabled"], mutates=False)
    return res.rc == 0
