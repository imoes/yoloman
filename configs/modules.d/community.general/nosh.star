def main(ctx, params):
    name = params["name"]
    state = params.get("state")
    enabled = params.get("enabled")
    preset = params.get("preset")
    user = params.get("user", False)

    # Mutually exclusive check for enabled and preset
    if enabled != None and preset != None:
        fail("enabled and preset are mutually exclusive")

    # Build system-control command prefix
    sys_ctl = ["system-control"]
    if user:
        sys_ctl.append("--user")

    # Find service path
    res = ctx.run(sys_ctl + ["find", name])
    if res.rc != 0:
        fail("service %s not found" % name)
    service_path = res.stdout.strip()

    # Helper to run system-control commands
    def sys_ctl_run(args, mutates=False):
        return ctx.run(sys_ctl + args, mutates=mutates)

    # Get service status helpers
    res = sys_ctl_run(["is-enabled", service_path])
    enabled_status = (res.rc == 0)

    res = sys_ctl_run(["preset", "--dry-run", service_path])
    preset_status = res.stdout.strip().startswith("enable")
    preset_effective = enabled_status == preset_status

    result = {
        "name": name,
        "service_path": service_path,
        "user": user,
        "enabled": enabled_status,
        "preset": preset_effective,
    }

    # Handle enabled/preset state changes
    if enabled != None or preset != None:
        if preset != None:
            # preset option takes effect only if set to true
            if preset and not preset_effective:
                if not ctx.check_mode:
                    res = sys_ctl_run(["preset", service_path], mutates=True)
                    if res.rc != 0:
                        fail("Unable to preset service %s: %s" % (name, res.stderr))
                result["preset"] = True
                result["enabled"] = True
            elif not preset and preset_effective:
                # No reverse preset support in original — fail on invalid request
                fail("preset=false is not supported by the nosh preset mechanism")
        elif enabled != None:
            desired = enabled
            if enabled_status != desired:
                action = "enable" if desired else "disable"
                if not ctx.check_mode:
                    res = sys_ctl_run([action, service_path], mutates=True)
                    if res.rc != 0:
                        fail("Unable to %s service %s: %s" % (action, name, res.stderr))
                result["enabled"] = desired
                result["preset"] = False

    # Handle state changes only if state specified
    if state != None:
        # Check service is loaded
        res = sys_ctl_run(["is-loaded", service_path])
        loaded = (res.rc == 0)
        result["state"] = state

        if not loaded:
            if state == "started" or state == "restarted" or state == "reloaded":
                action = "start"
                result["state"] = "started"
            elif state == "reset":
                if enabled_status:
                    action = "start"
                    result["state"] = "started"
                else:
                    result["state"] = None
            else:
                result["state"] = None
        else:
            # Get service status
            res = sys_ctl_run(["show-json", service_path])
            # parse JSON manually (no json module); find our service key
            output = res.stdout.strip()
            if not output.startswith("{") or not output.endswith("}"):
                fail("invalid JSON from system-control show-json")
            # Extract service_path entry: { "service_path": {...} }
            start_idx = output.find('"' + service_path + '":')
            if start_idx == -1:
                fail("service_path %s not found in JSON status" % service_path)
            start_idx = output.find("{", start_idx)
            if start_idx == -1:
                fail("invalid JSON structure")
            end_idx = start_idx + 1
            brace_count = 1
            while end_idx < len(output) and brace_count > 0 and output[end_idx] != "}":
                if output[end_idx] == "{":
                    brace_count += 1
                elif output[end_idx] == "}":
                    brace_count -= 1
                end_idx += 1
            if brace_count != 0:
                fail("malformed JSON object")
            json_obj = output[start_idx:end_idx]

            # Extract DaemontoolsEncoreState
            state_idx = json_obj.find('"DaemontoolsEncoreState":')
            if state_idx == -1:
                fail("DaemontoolsEncoreState not found in JSON")
            val_start = json_obj.find('"', state_idx + 25)
            if val_start == -1:
                fail("invalid DaemontoolsEncoreState value")
            val_start += 1
            val_end = json_obj.find('"', val_start)
            if val_end == -1:
                fail("invalid DaemontoolsEncoreState value")
            daemontools_state = json_obj[val_start:val_end]

            running = daemontools_state in ["starting", "started", "running"]

            # Build action based on state
            action = None
            if state == "started":
                if not running:
                    action = "start"
            elif state == "stopped":
                if running:
                    action = "stop"
            elif state == "reset":
                if enabled_status != running:
                    if running:
                        action = "stop"
                        result["state"] = "stopped"
                    else:
                        action = "start"
                        result["state"] = "started"
            elif state == "restarted":
                if not running:
                    action = "start"
                    result["state"] = "started"
                else:
                    action = "condrestart"
            elif state == "reloaded":
                if not running:
                    action = "start"
                    result["state"] = "started"
                else:
                    action = "hangup"

            if action:
                result["changed"] = True
                if not ctx.check_mode:
                    res = sys_ctl_run([action, service_path], mutates=True)
                    if res.rc != 0:
                        fail("Unable to %s service %s: %s" % (action, name, res.stderr))

        result["state"] = result.get("state")

    # Get final status if loaded
    if loaded:
        res = sys_ctl_run(["show-json", service_path])
        output = res.stdout.strip()
        start_idx = output.find('"' + service_path + '":')
        if start_idx == -1:
            fail("service_path %s not found in final status JSON" % service_path)
        start_idx = output.find("{", start_idx)
        if start_idx == -1:
            fail("invalid final status JSON structure")
        end_idx = start_idx + 1
        brace_count = 1
        while end_idx < len(output) and brace_count > 0 and output[end_idx] != "}":
            if output[end_idx] == "{":
                brace_count += 1
            elif output[end_idx] == "}":
                brace_count -= 1
            end_idx += 1
        if brace_count != 0:
            fail("malformed final status JSON object")
        json_obj = output[start_idx:end_idx]

        # Parse key=value pairs into result dict manually (no json module)
        status = {}
        # Strip braces and split on comma (simplified; assumes no nested objects)
        inner = json_obj[1:-1]
        # Simple key-value parser for flat JSON
        key = ""
        value = ""
        i = 0
        while i < len(inner):
            c = inner[i]
            if c == '"':
                # Start key
                i += 1
                key_start = i
                while i < len(inner) and inner[i] != '"':
                    i += 1
                key = inner[key_start:i]
                i += 1  # skip closing "
                # skip colon and whitespace
                while i < len(inner) and (inner[i] == " " or inner[i] == ":"):
                    i += 1
                if i < len(inner) and inner[i] == '"':
                    # String value
                    i += 1
                    val_start = i
                    while i < len(inner) and inner[i] != '"':
                        i += 1
                    value = inner[val_start:i]
                    i += 1
                elif i < len(inner) and inner[i].isdigit():
                    # Numeric value
                    val_start = i
                    while i < len(inner) and (inner[i].isdigit() or inner[i] == '-'):
                        i += 1
                    value = inner[val_start:i]
                else:
                    value = ""
            else:
                i += 1
            if key:
                # Map to simplified names where needed
                mapped_key = key
                if key == "DaemontoolsEncoreState":
                    mapped_key = "DaemontoolsEncoreState"
                elif key == "DaemontoolsState":
                    mapped_key = "DaemontoolsState"
                elif key == "Enabled":
                    mapped_key = "Enabled"
                elif key == "LogService":
                    mapped_key = "LogService"
                elif key == "MainPID":
                    mapped_key = "MainPID"
                elif key == "Paused":
                    mapped_key = "Paused"
                elif key == "ReadyAfterRun":
                    mapped_key = "ReadyAfterRun"
                elif key == "RemainAfterExit":
                    mapped_key = "RemainAfterExit"
                elif key == "Want":
                    mapped_key = "Want"
                status[mapped_key] = value
                key = ""
                value = ""

        result["status"] = status

    # Determine if change occurred
    if "changed" not in result:
        result["changed"] = False

    return {"changed": result["changed"], "msg": "", "data": result}
