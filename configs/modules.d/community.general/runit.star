def main(ctx, params):
    name = params["name"]
    state = params.get("state")
    enabled = params.get("enabled")
    service_dir = params.get("service_dir", "/var/service")
    service_src = params.get("service_src", "/etc/sv")

    svc_full = service_dir + "/" + name
    src_full = service_src + "/" + name

    # Check if service symlink exists (enabled)
    svc_exists = ctx.file_exists(svc_full)
    src_exists = ctx.file_exists(src_full)

    # Get current state via sv stat if service is enabled
    current_state = None
    if svc_exists:
        res = ctx.run(["sv", "status", svc_full])
        if res.rc == 0 and res.stdout != None:
            output = res.stdout.strip()
            # Parse sv status output: "run: /var/service/svc: (pid XXX) Ys\n" or "down: /var/service/svc: Zs, normally up\n"
            # Extract state from first word
            first_part = output.split(";")[0].strip()
            if first_part.startswith("run:"):
                current_state = "started"
            elif first_part.startswith("down:"):
                current_state = "stopped"
            else:
                current_state = "unknown"
        else:
            current_state = "stopped"
    else:
        current_state = "stopped"

    changed = False
    msg = ""

    # Handle enabled state
    if enabled != None and enabled != svc_exists:
        changed = True
        if ctx.check_mode:
            if enabled:
                msg = "would enable " + name
            else:
                msg = "would disable " + name
            return {"changed": True, "msg": msg, "data": {"enabled": enabled, "current_state": current_state}}
        else:
            if enabled:
                if not src_exists:
                    fail("Could not find source for service to enable (%s)." % src_full)
                # Create symlink using ln -s
                res = ctx.run(["ln", "-s", src_full, svc_full], mutates=True)
                if res.rc != 0:
                    fail("Error while linking service: " + res.stderr)
            else:
                # First force-stop the service
                res = ctx.run(["sv", "force-stop", src_full], mutates=True)
                # Then remove symlink
                res = ctx.run(["rm", "-f", svc_full], mutates=True)
                if res.rc != 0:
                    fail("Error while unlinking service: " + res.stderr)

    # Handle state transitions
    if state != None and state != current_state:
        changed = True
        if ctx.check_mode:
            msg = "would " + state + " " + name
            return {"changed": True, "msg": msg, "data": {"enabled": enabled, "current_state": current_state}}
        else:
            # Map state to sv command
            cmd_map = {
                "started": ["sv", "start", svc_full],
                "stopped": ["sv", "stop", svc_full],
                "once": ["sv", "once", svc_full],
                "reloaded": ["sv", "reload", svc_full],
                "restarted": ["sv", "restart", svc_full],
                "killed": ["sv", "force-stop", svc_full],
            }
            cmd = cmd_map.get(state)
            if cmd == None:
                fail("Unsupported state: " + state)
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Failed to " + state + " service: " + res.stderr)
            # Verify new state for started/stopped
            if state in ["started", "stopped"]:
                new_res = ctx.run(["sv", "status", svc_full])
                if new_res.rc == 0 and new_res.stdout != None:
                    new_output = new_res.stdout.strip().split(";")[0].strip()
                    expected_prefix = "run:" if state == "started" else "down:"
                    if not new_output.startswith(expected_prefix):
                        fail("Service " + name + " did not enter expected " + state + " state")

    # No change needed
    return {"changed": False, "msg": name + " is in desired state", "data": {"enabled": svc_exists, "state": current_state}}
