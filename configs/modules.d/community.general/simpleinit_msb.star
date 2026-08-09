def main(ctx, params):
    name = params["name"]
    state = params.get("state")
    enabled = params.get("enabled")

    # At least one of state or enabled must be provided
    if state == None and enabled == None:
        fail("at least one of state and enabled is required")

    # Find telinit command
    paths = ["/sbin", "/usr/sbin", "/bin", "/usr/bin"]
    res = ctx.run(["which", "telinit"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["find", "/sbin", "/usr/sbin", "/bin", "/usr/bin", "-name", "telinit", "-type", "f", "-print", "-quit"], mutates=False)
        if res.rc != 0 or res.stdout.strip() == "":
            fail("cannot find telinit script for simpleinit-msb, aborting...")
        telinit_cmd = res.stdout.strip()
    else:
        telinit_cmd = res.stdout.strip()

    # Check if /etc/init.d/smgl_init exists (basic sanity check)
    if not ctx.file_exists("/etc/init.d/smgl_init"):
        fail("simpleinit-msb not detected (/etc/init.d/smgl_init missing), aborting...")

    # Verify service exists
    res = ctx.run([telinit_cmd, "list"], mutates=False)
    if res.rc != 0:
        fail("telinit list failed: " + res.stderr)
    service_exists = False
    for line in res.stdout.split("\n"):
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == name:
            service_exists = True
            break
    if not service_exists:
        fail("telinit could not find the requested service: " + name)

    # Handle enabled state
    changed = False
    if enabled != None:
        # Check if already enabled/disabled
        res = ctx.run([telinit_cmd, "list", "boot"], mutates=False)
        if res.rc != 0:
            fail("telinit list boot failed: " + res.stderr)

        currently_enabled = False
        for line in res.stdout.split("\n"):
            if line.strip() == name:
                currently_enabled = True
                break

        if enabled and not currently_enabled:
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable service " + name}
            res = ctx.run([telinit_cmd, "bootenable", name], mutates=True)
            if res.rc != 0 and "already enabled" not in res.stderr:
                fail("failed to enable service " + name + ": " + res.stderr)
            changed = True
        elif not enabled and currently_enabled:
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable service " + name}
            res = ctx.run([telinit_cmd, "bootdisable", name], mutates=True)
            if res.rc != 0 and "already disabled" not in res.stderr:
                fail("failed to disable service " + name + ": " + res.stderr)
            changed = True

    # Skip service state changes if only enabling/disabling
    if state == None:
        return {"changed": changed, "msg": ""}

    # Determine service status
    res = ctx.run([telinit_cmd, "run", name, "status"], mutates=False)
    running = False
    if res.rc == 0 and res.stdout.find("is running") != -1:
        running = True
    elif res.stdout.find("is not running") != -1:
        running = False
    else:
        # Fallback: try to start and check if it's already started
        res = ctx.run([telinit_cmd, "run", name, "status"], mutates=False)
        if res.rc != 0:
            running = False
        else:
            running = True

    # Decide action
    action = None
    if state in ["started", "running"]:
        if not running:
            action = "start"
            changed = True
    elif state == "stopped":
        if running:
            action = "stop"
            changed = True
    elif state == "restarted":
        action = "restart"
        changed = True
    elif state == "reloaded":
        if not running:
            action = "start"
        else:
            action = "reload"
        changed = True

    if not changed:
        return {"changed": False, "msg": "service already in desired state"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would " + state + " service " + name}

    # Execute action
    if action == "start":
        res = ctx.run([telinit_cmd, "run", name, "start"], mutates=True)
    elif action == "stop":
        res = ctx.run([telinit_cmd, "run", name, "stop"], mutates=True)
    elif action == "restart":
        res = ctx.run([telinit_cmd, "run", name, "restart"], mutates=True)
    elif action == "reload":
        res = ctx.run([telinit_cmd, "run", name, "reload"], mutates=True)
    else:
        fail("unknown action: " + action)

    if res.rc != 0:
        fail("failed to " + action + " service " + name + ": " + res.stderr)

    return {"changed": True, "msg": "service " + state}
