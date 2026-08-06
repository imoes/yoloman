def main(ctx, params):
    name = params["name"]
    state = params.get("state")
    enabled = params.get("enabled")
    downed = params.get("downed")
    service_dir = params.get("service_dir", "/service")
    service_src = params.get("service_src", "/etc/service")

    svc_full = service_dir + "/" + name
    src_full = service_src + "/" + name

    # Detect current state
    enabled_current = ctx.file_exists(svc_full)
    downed_current = False
    svc_state = "stopped"
    pid = None
    duration = None
    full_state = ""

    if enabled_current:
        # Service is enabled — check down file and status
        downed_current = ctx.file_exists(svc_full + "/down")
        res = ctx.run([ctx.get_bin_path("svstat"), svc_full])
        full_state = res.stdout.strip()
        # Parse status: e.g., "up (pid 1234) 123 seconds"
        # Check for " up " or " down "
        if " up " in full_state:
            svc_state = "started"
        elif " down " in full_state:
            svc_state = "stopped"
        else:
            svc_state = "unknown"

        # Extract pid and duration if present
        # Simple string parsing (no regex)
        lines = full_state.splitlines()
        for line in lines:
            line = line.strip()
            # pid
            if "(pid " in line:
                idx = line.find("(pid ")
                sub = line[idx + 5:]
                end = sub.find(")")
                if end != -1:
                    pid_str = sub[:end].strip()
                    if len(pid_str) > 0 and pid_str.isdigit():
                        pid = int(pid_str)
            # duration in seconds
            if " seconds" in line:
                idx = line.rfind(" ")
                dur_str = line[idx+1:].strip()
                if dur_str.endswith("seconds"):
                    dur_val = dur_str[:-7].strip()
                    if dur_val.isdigit():
                        duration = int(dur_val)

    # Build initial report
    def report():
        return {
            "state": svc_state,
            "enabled": enabled_current,
            "downed": downed_current,
            "svc_full": svc_full,
            "src_full": src_full,
            "pid": pid,
            "duration": duration,
            "full_state": full_state
        }

    changed = False

    # Handle enabled state change
    if enabled != None:
        if enabled != enabled_current:
            changed = True
            if not ctx.check_mode:
                if enabled:
                    # create symlink from src_full to svc_full
                    if not ctx.file_exists(src_full):
                        fail("Could not find source for service to enable (%s)." % src_full)
                    ctx.run(["ln", "-sf", src_full, svc_full], mutates=True)
                else:
                    # remove symlink
                    if ctx.file_exists(svc_full):
                        ctx.run(["rm", "-f", svc_full], mutates=True)
                    # Also disable log if exists
                    src_log = src_full + "/log"
                    if ctx.file_exists(src_log):
                        ctx.run(["svc", "-dx", src_log], mutates=True)

    # Handle state change
    if state != None:
        desired_state = state
        actual_state = svc_state.rstrip("ing") if svc_state.endswith("ing") else svc_state
        if desired_state == "started" and actual_state != "started":
            changed = True
            if not ctx.check_mode:
                ctx.run(["svc", "-u", svc_full], mutates=True)
        elif desired_state == "stopped" and actual_state != "stopped":
            changed = True
            if not ctx.check_mode:
                ctx.run(["svc", "-d", svc_full], mutates=True)
        elif desired_state == "restarted":
            changed = True
            if not ctx.check_mode:
                ctx.run(["svc", "-t", svc_full], mutates=True)
        elif desired_state == "killed":
            changed = True
            if not ctx.check_mode:
                ctx.run(["svc", "-k", svc_full], mutates=True)
        elif desired_state == "reloaded":
            changed = True
            if not ctx.check_mode:
                ctx.run(["svc", "-1", svc_full], mutates=True)
        elif desired_state == "once":
            changed = True
            if not ctx.check_mode:
                ctx.run(["svc", "-o", svc_full], mutates=True)

    # Handle downed state change
    if downed != None:
        if downed != downed_current:
            changed = True
            if not ctx.check_mode:
                d_file = svc_full + "/down"
                if downed:
                    # create empty down file
                    ctx.file_write(d_file, "", mode="0644")
                else:
                    # remove down file
                    if ctx.file_exists(d_file):
                        ctx.run(["rm", "-f", d_file], mutates=True)

    # If check_mode and changed, just report
    if ctx.check_mode and changed:
        return {"changed": True, "msg": "would change service state", "svc": report()}

    # Re-scan state to update report
    final_report = report()

    msg = "no change"
    if changed:
        msg = "service state updated"
    return {"changed": changed, "msg": msg, "svc": final_report}
