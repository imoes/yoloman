def main(ctx, params):
    path = params["path"]
    state = params.get("state", "present")
    holder = params.get("holder")
    divert = params.get("divert")
    rename = params.get("rename", False)
    force = params.get("force", False)

    # dpkg-divert is required
    dpkg_divert = ctx.run(["which", "dpkg-divert"])
    if dpkg_divert.rc != 0:
        fail("dpkg-divert command not found")
    DPKG_DIVERT = dpkg_divert.stdout.strip()

    # Check dpkg version (need >= 1.15.0)
    res = ctx.run([DPKG_DIVERT, "--version"])
    if res.rc != 0:
        fail("failed to get dpkg-divert version")
    version_line = res.stdout.split("\n")[0] if res.stdout else ""
    version_match = ""
    for token in version_line.split():
        if token.replace(".", "").isdigit() and token.count(".") == 1:
            version_match = token
            break
    if not version_match:
        fail("failed to parse dpkg-divert version")
    
    # Simple version comparison: "major.minor"
    def version_tuple(v):
        parts = v.split(".")
        if len(parts) < 2:
            parts.append("0")
        if parts[0].isdigit() and parts[1].isdigit():
            return (int(parts[0]), int(parts[1]))
        else:
            fail("invalid dpkg-divert version: " + v)
    
    current_version = version_tuple(version_match)
    if current_version < (1, 15):
        fail("Unsupported dpkg version (<1.15.0).")
    
    # --no-rename is supported in >= 1.19.1
    no_rename_supported = current_version >= (1, 19, 1)

    # Check if path exists (for rename logic)
    path_exists = ctx.file_exists(path)

    # Get current diversion state via dpkg-divert --listpackage and --truename
    def get_diversion(p):
        div = {"path": p, "state": "absent", "divert": None, "holder": None}
        res = ctx.run([DPKG_DIVERT, "--listpackage", p])
        if res.rc == 0 and res.stdout.strip():
            div["state"] = "present"
            div["holder"] = res.stdout.rstrip()
            res2 = ctx.run([DPKG_DIVERT, "--truename", p])
            if res2.rc == 0 and res2.stdout.strip():
                div["divert"] = res2.stdout.rstrip()
        return div

    diversion_before = get_diversion(path)

    # Compute desired state
    diversion_wanted = {"path": path, "state": state}
    if state == "present":
        if holder and holder != "LOCAL":
            diversion_wanted["holder"] = holder
        else:
            diversion_wanted["holder"] = "LOCAL"
        if divert:
            diversion_wanted["divert"] = divert
        else:
            diversion_wanted["divert"] = path + ".distrib"
    else:
        diversion_wanted["holder"] = None
        diversion_wanted["divert"] = None

    # Build main command
    MAINCOMMAND = [DPKG_DIVERT]
    if rename:
        MAINCOMMAND.append("--rename")
    elif no_rename_supported:
        MAINCOMMAND.append("--no-rename")

    if state == "present":
        if holder and holder != "LOCAL":
            MAINCOMMAND.extend(["--package", holder])
        else:
            MAINCOMMAND.append("--local")
        if divert:
            MAINCOMMAND.extend(["--divert", divert])
        MAINCOMMAND.extend(["--add", path])
    else:
        MAINCOMMAND.extend(["--remove", path])

    commands = []
    messages = []

    # Check if already in desired state
    if diversion_wanted == diversion_before:
        return {
            "changed": False,
            "msg": "diversion already in desired state",
            "diversion": diversion_before,
            "commands": [],
            "messages": [],
        }

    # Prepare check_mode run
    test_command = list(MAINCOMMAND)
    test_command.insert(1, "--test")

    # Check for rename requirements (target file existence)
    truename_exists = False
    target_exists = False
    if diversion_before["state"] == "present" and diversion_before["divert"]:
        truename_exists = ctx.file_exists(diversion_before["divert"])
    if state == "present":
        target = diversion_wanted["divert"]
        if target:
            target_exists = ctx.file_exists(target)

    # Run main command (possibly with --test if check_mode)
    if ctx.check_mode:
        res = ctx.run(test_command)
    else:
        res = ctx.run(MAINCOMMAND)

    if res.rc == 0:
        messages.append(res.stdout.rstrip() if res.stdout else "")

    # Handle failure cases (state mismatch or rename issues)
    elif state != diversion_before["state"]:
        # Rename problem
        if rename and path_exists and (
            (state == "absent" and truename_exists) or
            (state == "present" and target_exists)
        ):
            if not force:
                fail("Set 'force' param to True to force renaming of files.")
        else:
            fail("Unexpected error while changing state of the diversion: " + res.stderr)

        # Force removal and retry
        to_remove = target if state == "present" else path
        if not ctx.check_mode:
            # Remove the blocking file
            if ctx.file_exists(to_remove):
                rmres = ctx.run(["rm", "-f", to_remove])
                if rmres.rc != 0:
                    fail("Failed to remove blocking file " + to_remove)
            res = ctx.run(MAINCOMMAND)
            if res.rc != 0:
                fail("dpkg-divert command failed after removing blocking file: " + res.stderr)
            messages.append(res.stdout.rstrip() if res.stdout else "")
        else:
            # check_mode: predict success
            pass

    # Handle holder/divert update (need remove+add)
    else:
        # Build remove command
        RMDIVERSION = [DPKG_DIVERT, "--remove", path]
        if no_rename_supported:
            RMDIVERSION.insert(1, "--no-rename")

        if ctx.check_mode:
            RMDIVERSION.insert(1, "--test")
            rmres = ctx.run(RMDIVERSION)
            messages.append(rmres.stdout.rstrip() if rmres.stdout else "Running in check mode")
            res = struct(rc=0, stdout="", stderr="")
        else:
            rmres = ctx.run(RMDIVERSION)
            if rmres.rc != 0:
                fail("dpkg-divert remove failed: " + rmres.stderr)
            messages.append(rmres.stdout.rstrip() if rmres.stdout else "")

            # Then add with new settings
            ADDCOMMAND = [DPKG_DIVERT]
            if rename:
                ADDCOMMAND.append("--rename")
            elif no_rename_supported:
                ADDCOMMAND.append("--no-rename")
            if holder and holder != "LOCAL":
                ADDCOMMAND.extend(["--package", holder])
            else:
                ADDCOMMAND.append("--local")
            if divert:
                ADDCOMMAND.extend(["--divert", divert])
            ADDCOMMAND.extend(["--add", path])
            res = ctx.run(ADDCOMMAND)
            if res.rc != 0:
                fail("dpkg-divert add failed: " + res.stderr)
            messages.append(res.stdout.rstrip() if res.stdout else "")

            # Handle rename of diverted file
            old_divert = diversion_before["divert"]
            new_divert = diversion_wanted["divert"]
            if new_divert and old_divert and new_divert != old_divert:
                if ctx.file_exists(old_divert) and not ctx.file_exists(new_divert):
                    mvres = ctx.run(["mv", old_divert, new_divert])
                    if mvres.rc != 0:
                        # Ignore mv failure as per original code
                        pass

    # Get final state
    if ctx.check_mode:
        diversion_after = diversion_wanted
    else:
        diversion_after = get_diversion(path)

    # Build commands list
    if len(commands) == 0:
        commands = [' '.join(MAINCOMMAND)] if state == "present" or state != diversion_before["state"] else []

    changed = (diversion_after != diversion_before)

    return {
        "changed": changed,
        "msg": "diversion updated" if changed else "diversion unchanged",
        "diversion": diversion_after,
        "commands": commands,
        "messages": messages,
    }
