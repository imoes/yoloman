def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "present")
    value = params.get("value")
    add_mode = params.get("add_mode", "replace-all")
    scope = params.get("scope")
    repo = params.get("repo")
    file_path = params.get("file")
    list_all = params.get("list_all", False)

    # Validate required parameters
    if not list_all and not name:
        fail("one of name or list_all is required")
    if list_all and (name or value or state != "present"):
        fail("list_all cannot be combined with name, value, or state")
    if scope == "local" and not repo:
        fail("repo is required when scope is local")
    if scope == "file" and not file_path:
        fail("file is required when scope is file")

    # Determine scope
    if scope:
        actual_scope = scope
    elif list_all:
        actual_scope = ""
    else:
        actual_scope = "system"

    # Build base git config arguments
    git = "git"
    base_args = [git, "config", "--includes"]

    if actual_scope == "file":
        base_args.extend(["-f", file_path])
    elif actual_scope:
        base_args.append("--" + actual_scope)

    # Read current values
    read_args = list(base_args)
    if list_all:
        read_args.append("-l")
    if name:
        read_args.extend(["--get-all", name])

    res = ctx.run(read_args, mutates=False)
    if res.rc >= 2:
        fail("failed to read git config: " + res.stderr)
    if res.rc == 128 and "unable to read config file" in res.stderr and actual_scope and list_all:
        # Empty scope config file
        return {"changed": False, "config_values": {}}

    old_values = []
    if res.stdout.strip():
        old_values = res.stdout.strip().splitlines()

    if list_all:
        config_values = {}
        for line in old_values:
            if "=" in line:
                k, v = line.split("=", 1)
                config_values[k] = v
        return {"changed": False, "config_values": config_values}
    elif not value and state == "present":
        # Read mode
        result_value = old_values[0] if old_values else ""
        return {"changed": False, "config_value": result_value}
    elif state == "absent" and not old_values:
        return {"changed": False, "msg": "no setting to unset"}

    # Determine if change is needed
    if state == "present" and value:
        if value in old_values and (len(old_values) == 1 or add_mode == "add"):
            return {"changed": False, "msg": ""}

    # Prepare modification arguments
    set_args = list(base_args)
    if state == "absent":
        set_args.extend(["--unset-all", name])
    else:
        set_args.extend(["--" + add_mode, name, value])

    if ctx.check_mode:
        return {"changed": True, "msg": "setting changed"}

    # Execute modification
    res = ctx.run(set_args, mutates=True)
    if res.rc != 0:
        fail("failed to set git config: " + res.stderr)

    # Determine new state
    if state == "absent":
        after_values = []
    elif add_mode == "add":
        after_values = old_values + [value]
    else:
        after_values = [value]

    return {
        "changed": True,
        "msg": "setting changed",
        "diff": {
            "before_header": " ".join(set_args),
            "before": "\n".join(old_values) if old_values else "",
            "after_header": " ".join(set_args),
            "after": "\n".join(after_values) if after_values else ""
        }
    }
