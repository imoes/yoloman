def main(ctx, params):
    name = params["name"]
    flatpakrepo_url = params.get("flatpakrepo_url", "")
    method = params.get("method", "system")
    state = params.get("state", "present")
    enabled = params.get("enabled", True)
    executable = params.get("executable", "flatpak")

    # Validate method
    if method not in ("system", "user"):
        fail("method must be 'system' or 'user', got: " + method)

    # Check flatpak executable
    res = ctx.run([executable, "--version"])
    if res.rc != 0:
        fail("Executable '" + executable + "' was not found on the system.")

    # Get remote list (read-only, always run even in check_mode)
    list_cmd = [executable, "remote-list", "--show-disabled", "--" + method]
    list_res = ctx.run(list_cmd, mutates=False)
    remote_lines = list_res.stdout.strip().split("\n") if list_res.stdout.strip() else []

    # Parse remote existence and enabled state
    remote_exists = False
    remote_enabled_flag = False

    for line in remote_lines:
        parts = line.split()
        if len(parts) == 0:
            continue
        if parts[0] == name:
            remote_exists = True
            # Check if disabled: presence of 'disabled' in second part (e.g., "flathub\tdisabled")
            if len(parts) > 1 and "disabled" in parts[1]:
                remote_enabled_flag = False
            else:
                remote_enabled_flag = True
            break

    # Determine changes needed
    change_needed = False
    msg_parts = []

    if state == "present":
        if not remote_exists:
            change_needed = True
            msg_parts.append("add remote")
        else:
            # Check enabled state
            if enabled and not remote_enabled_flag:
                change_needed = True
                msg_parts.append("enable remote")
            elif not enabled and remote_enabled_flag:
                change_needed = True
                msg_parts.append("disable remote")
    else:  # absent
        if remote_exists:
            change_needed = True
            msg_parts.append("remove remote")

    # Handle check_mode
    if ctx.check_mode:
        if change_needed:
            return {"changed": True, "msg": "would " + ", ".join(msg_parts)}
        else:
            return {"changed": False, "msg": name + " already in desired state"}

    # Execute changes if needed
    if not change_needed:
        return {"changed": False, "msg": name + " already in desired state"}

    if state == "present":
        if not remote_exists:
            cmd = [executable, "remote-add", "--" + method, name, flatpakrepo_url]
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Failed to add remote '" + name + "': " + res.stderr)
        else:
            # Enable/disable only
            if enabled and not remote_enabled_flag:
                cmd = [executable, "remote-modify", "--enable", "--" + method, name]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    fail("Failed to enable remote '" + name + "': " + res.stderr)
            if not enabled and remote_enabled_flag:
                cmd = [executable, "remote-modify", "--disable", "--" + method, name]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    fail("Failed to disable remote '" + name + "': " + res.stderr)
    else:  # absent
        cmd = [executable, "remote-delete", "--" + method, "--force", name]
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to remove remote '" + name + "': " + res.stderr)

    return {"changed": True, "msg": ", ".join(msg_parts)}
