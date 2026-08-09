def main(ctx, params):
    name = params["name"]
    path = params["path"]
    link = params.get("link")
    priority = params.get("priority", 50)
    state = params.get("state", "selected")
    subcommands = params.get("subcommands")

    # Check mode support
    check_mode = ctx.check_mode

    # Ensure update-alternatives exists
    res = ctx.run(["which", "update-alternatives"])
    if res.rc != 0:
        fail("update-alternatives not found on system")

    # Parse current state
    current_mode = None
    current_path = None
    current_link = None
    current_alternatives = {}

    display_res = ctx.run(["update-alternatives", "--display", name])
    if display_res.rc == 0:
        output = display_res.stdout
        lines = output.split("\n")

        # Parse mode
        for line in lines:
            stripped = line.strip()
            if "mode" in stripped:
                if stripped.startswith(" - "):
                    status_part = stripped[3:].strip()
                    if "status is " in status_part:
                        status_part = status_part.split("status is ")[1]
                    current_mode = status_part.split(" ")[0].strip()
                    break

        # Parse current link target
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("link currently points to "):
                current_path = stripped.replace("link currently points to ", "").strip()
                break

        # Parse current link path
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("link ") and " is " in stripped:
                parts = stripped.split(" is ")
                if len(parts) == 2:
                    current_link = parts[1].strip()
                break

        # Parse alternatives and their priorities
        in_alternative_block = False
        for line in lines:
            stripped = line.strip()
            # Match alternative entries: /path/to/exec - priority XXX
            if stripped.startswith("/") and " - priority " in stripped:
                in_alternative_block = True
                parts = stripped.split(" - priority ")
                if len(parts) >= 2:
                    alt_path = parts[0].strip()
                    prio_parts = parts[1].split(" ")
                    prio = int(prio_parts[0])
                    subcmd_part = " ".join(prio_parts[1:]) if len(prio_parts) > 1 else ""
                    
                    # Parse subcommands/slaves if present
                    subcmds = []
                    subcmd_map = {}
                    # Build slave map from display output
                    for sub_line in lines:
                        sub_stripped = sub_line.strip()
                        if sub_stripped.startswith("slave ") or sub_stripped.startswith("follower "):
                            sub_parts = sub_stripped.split(" is ")
                            if len(sub_parts) == 2:
                                subcmd_map[sub_parts[0].split(" ")[1].strip()] = sub_parts[1].strip()
                    
                    # Find subcommand lines under this alternative
                    next_idx = lines.index(line) + 1
                    while next_idx < len(lines) and lines[next_idx].startswith(" "):
                        sub_line = lines[next_idx].strip()
                        if sub_line.startswith("slave") or sub_line.startswith("follower"):
                            sub_parts = sub_line.split(": ")
                            if len(sub_parts) == 2:
                                sub_name = sub_parts[0].split(" ")[1].strip()
                                sub_path = sub_parts[1].strip()
                                if sub_path != "(null)":
                                    link_val = subcmd_map.get(sub_name)
                                    if link_val:
                                        subcmds.append({
                                            "name": sub_name,
                                            "path": sub_path,
                                            "link": link_val
                                        })
                        next_idx += 1
                        if next_idx >= len(lines):
                            break
                    
                    current_alternatives[alt_path] = {
                        "priority": prio,
                        "subcommands": subcmds
                    }

    # Determine effective link value
    effective_link = link if link else current_link

    # Determine state behavior
    should_install = False
    should_set = False
    should_auto = False
    should_remove = False

    if state == "absent":
        should_remove = path in current_alternatives
    else:
        # Install check: path not installed, or priority differs, or subcommands differ
        if path not in current_alternatives:
            should_install = True
        else:
            # Check priority difference
            if priority != None and current_alternatives.get(path, {}).get("priority") != priority:
                should_install = True
            # Check subcommands difference
            elif subcommands:
                current_subs = current_alternatives.get(path, {}).get("subcommands", [])
                current_subs_set = [str(s) for s in current_subs]
                new_subs_set = [str(s) for s in subcommands]
                if sorted(current_subs_set) != sorted(new_subs_set):
                    should_install = True

        # Check state-specific actions
        if state == "selected":
            if current_path != path:
                should_set = True
        elif state == "auto":
            if current_mode == "manual":
                should_auto = True

    # Execute actions
    msg_parts = []

    # Remove action
    if should_remove:
        if not check_mode:
            remove_res = ctx.run(["update-alternatives", "--remove", name, path], mutates=True)
            if remove_res.rc != 0:
                fail("Failed to remove alternative: " + remove_res.stderr)
        msg_parts.append("Remove alternative '%s' from '%s'." % (path, name))
    
    # Install action
    if should_install:
        if not path or not effective_link:
            fail("Needed to install the alternative, but unable to do so as we are missing the link")
        
        # Check executable exists
        if not ctx.file_exists(path):
            fail("Specified path %s does not exist" % path)

        # Build command
        cmd = ["update-alternatives", "--install", effective_link, name, path, str(priority)]
        
        # Add subcommands/slaves
        if subcommands:
            for sub in subcommands:
                cmd += ["--slave", sub["link"], sub["name"], sub["path"]]

        if not check_mode:
            install_res = ctx.run(cmd, mutates=True)
            if install_res.rc != 0:
                fail("Failed to install alternative: " + install_res.stderr)
        
        msg_parts.append("Install alternative '%s' for '%s'." % (path, name))
    
    # Set action (manual selection)
    if should_set:
        if not check_mode:
            set_res = ctx.run(["update-alternatives", "--set", name, path], mutates=True)
            if set_res.rc != 0:
                fail("Failed to set alternative: " + set_res.stderr)
        msg_parts.append("Set alternative '%s' for '%s'." % (path, name))
    
    # Auto action (reset to auto mode)
    if should_auto:
        if not check_mode:
            auto_res = ctx.run(["update-alternatives", "--auto", name], mutates=True)
            if auto_res.rc != 0:
                fail("Failed to set auto mode: " + auto_res.stderr)
        msg_parts.append("Set alternative to auto for '%s'." % name)

    # Check mode handling: if we predicted changes but in check_mode, return change=True
    if (should_install or should_set or should_auto or should_remove) and check_mode:
        return {"changed": True, "msg": " would ".join(msg_parts)}

    changed = (should_install or should_set or should_auto or should_remove)
    return {
        "changed": changed,
        "msg": " ".join(msg_parts) if msg_parts else "No changes required"
    }
