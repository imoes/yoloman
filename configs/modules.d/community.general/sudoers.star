def main(ctx, params):
    name = params["name"]
    user = params.get("user")
    group = params.get("group")
    state = params.get("state", "present")
    nopassword = params.get("nopassword", True)
    setenv = params.get("setenv", False)
    host = params.get("host", "ALL")
    runas = params.get("runas")
    sudoers_path = params.get("sudoers_path", "/etc/sudoers.d")
    commands = params.get("commands")
    validation = params.get("validation", "detect")

    # Validate mutually exclusive options
    if user != None and group != None:
        fail("user and group are mutually exclusive")

    # Validate required parameters for present state
    if state == "present" and commands == None:
        fail("commands is required when state is present")

    # Ensure sudoers path exists (create if needed)
    if not ctx.file_exists(sudoers_path):
        if ctx.check_mode:
            # In check_mode, we just verify the directory path would be created
            pass
        else:
            # Try to create the directory; fail if it's not possible
            res = ctx.run(["mkdir", "-p", sudoers_path])
            if res.rc != 0:
                fail("failed to create sudoers directory %s: %s" % (sudoers_path, res.stderr))

    # Compute expected file path
    file_path = sudoers_path.rstrip("/") + "/" + name

    # Build the sudoers line
    if user != None:
        owner = user
    elif group != None:
        owner = "%" + group
    else:
        fail("either user or group is required")

    commands_str = ", ".join(commands)

    nopasswd_str = "NOPASSWD:" if nopassword else ""
    setenv_str = "SETENV:" if setenv else ""
    runas_str = "(" + runas + ")" if runas != None else ""

    expected_line = owner + " " + host + "=" + runas_str + nopasswd_str + setenv_str + " " + commands_str + "\n"

    # Handle absent state
    if state == "absent":
        if ctx.file_exists(file_path):
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove sudoers rule %s" % name}
            res = ctx.run(["rm", "-f", file_path], mutates=True)
            if res.rc != 0:
                fail("failed to delete %s: %s" % (file_path, res.stderr))
            return {"changed": True, "msg": "removed sudoers rule %s" % name}
        else:
            return {"changed": False, "msg": "sudoers rule %s does not exist" % name}

    # Handle present state

    # Validation step
    if validation != "absent":
        res = ctx.run(["which", "visudo"], mutates=False)
        if validation == "required" and res.rc != 0:
            fail("visudo is required but not found")
        if res.rc == 0:
            visudo = res.stdout.strip()
            # Validation in check_mode is skipped per Ansible convention
            if not ctx.check_mode:
                # Write to temp file and validate
                tmp_path = "/tmp/sudoers-%s" % name
                ctx.file_write(tmp_path, expected_line)
                res = ctx.run([visudo, "-c", "-f", tmp_path])
                if res.rc != 0:
                    fail("validation failed: %s" % res.stderr)
                # Cleanup temp file
                ctx.run(["rm", "-f", tmp_path])

    # Check if file exists and matches
    if ctx.file_exists(file_path):
        current = ctx.file_read(file_path)
        current_mode_raw = ctx.stat(file_path)["mode"]
        # Mode is string like "0644"; compare to 0o440 = "0440"
        current_mode_octal = current_mode_raw.zfill(4)
        expected_mode_octal = "0440"
        if current == expected_line and current_mode_octal == expected_mode_octal:
            return {"changed": False, "msg": "sudoers rule %s already exists and is correct" % name}

    # If here, need to write or update
    if ctx.check_mode:
        return {"changed": True, "msg": "would update sudoers rule %s" % name}

    # Write file
    changed = ctx.file_write(file_path, expected_line, mode="0440")
    return {"changed": changed, "msg": "sudoers rule %s updated" % name}
