def main(ctx, params):
    target = params["target"]
    ftype = params.get("ftype", "a")
    setype = params.get("setype")
    substitute = params.get("substitute")
    seuser = params.get("seuser")
    serange = params.get("selevel")
    state = params.get("state", "present")
    reload_policy = params.get("reload", True)
    ignore_selinux_state = params.get("ignore_selinux_state", False)

    # Validate mutually exclusive options
    if setype != None and substitute != None:
        fail("setype and substitute are mutually exclusive")
    if substitute != None:
        if ftype != "a":
            fail("ftype cannot be specified with substitute")
        if seuser != None:
            fail("seuser cannot be specified with substitute")
        if serange != None:
            fail("selevel/serange cannot be specified with substitute")

    # Check for state=present requirements
    if state == "present" and setype == None and substitute == None:
        fail("one of setype or substitute is required when state=present")

    # Get SELinux runtime status
    if not ignore_selinux_state:
        res = ctx.run(["getenforce"])
        if res.rc != 0 or "Disabled" in res.stdout:
            fail("SELinux is disabled on this host")

    # Prepare file type string mapping
    ftype_map = {
        "a": "all files",
        "b": "block device",
        "c": "character device",
        "d": "directory",
        "f": "regular file",
        "l": "symbolic link",
        "p": "named pipe",
        "s": "socket",
    }
    ftype_str = ftype_map[ftype]

    # Determine the command to run based on state
    changed = False
    diff = ""
    msg = ""

    if state == "present":
        # Check if entry exists
        res = ctx.run(["semanage", "fcontext", "-l", "-C"], ok_codes=[0, 1])
        # Parse output for existing entry
        lines = res.stdout.splitlines() if res.stdout else []
        existing = None
        for line in lines:
            parts = line.split()
            if len(parts) >= 3 and parts[0] == target and parts[1] == ftype_str:
                existing = line
                break

        if existing != None:
            # Parse existing record: "target      ftype_str    user:role:type:range"
            # Format: "%-50s  %-12s  %s:%s:%s:%s"
            existing_parts = existing.split()
            if len(existing_parts) >= 4:
                # Extract context parts from the last 4 fields
                context = existing_parts[2] + ":" + existing_parts[3] + ":" + existing_parts[4] + ":" + (existing_parts[5] if len(existing_parts) > 5 else "s0")
                # We only need to parse if user set something different
                orig_user = existing_parts[2]
                orig_type = existing_parts[4]
                orig_range = existing_parts[5] if len(existing_parts) > 5 else "s0"

                final_user = seuser if seuser != None else orig_user
                final_range = serange if serange != None else orig_range

                if setype != orig_type or final_user != orig_user or final_range != orig_range:
                    changed = True
                    if not ctx.check_mode:
                        if seuser == None and seuser == None and serange == None:
                            res = ctx.run(["semanage", "fcontext", "-m", "-f", ftype, "-t", setype, target], mutates=True)
                        else:
                            args = ["semanage", "fcontext", "-m", "-f", ftype]
                            if seuser != None:
                                args += ["-u", seuser]
                            if serange != None:
                                args += ["-r", serange]
                            args += ["-t", setype, target]
                            res = ctx.run(args, mutates=True)
                        if res.rc != 0:
                            fail("failed to modify fcontext: " + res.stderr)
                msg = "fcontext already present" if not changed else "fcontext updated"
                if ctx.check_mode and changed:
                    msg = "would update fcontext"

            # For diff
            if ctx.check_mode and changed:
                diff += "# Change to semanage file context mappings\n"
                diff += "-%s      %s      %s:%s:%s:%s\n" % (target, ftype_str, orig_user, "object_r", orig_type, orig_range)
                diff += "+%s      %s      %s:%s:%s:%s\n" % (target, ftype_str, final_user, "object_r", setype, final_range)
        else:
            # Add new entry
            changed = True
            if not ctx.check_mode:
                args = ["semanage", "fcontext", "-a", "-f", ftype]
                final_user = seuser if seuser != None else "system_u"
                final_range = serange if serange != None else "s0"
                if seuser != None:
                    args += ["-u", seuser]
                if serange != None:
                    args += ["-r", serange]
                args += ["-t", setype, target]
                res = ctx.run(args, mutates=True)
                if res.rc != 0:
                    fail("failed to add fcontext: " + res.stderr)
            msg = "fcontext added"
            if ctx.check_mode:
                msg = "would add fcontext"
            diff += "# Addition to semanage file context mappings\n"
            diff += "+%s      %s      %s:%s:%s:%s\n" % (target, ftype_str, final_user, "object_r", setype, final_range)

        # Handle substitute (equal)
        if substitute != None:
            res = ctx.run(["semanage", "fcontext", "-l", "-C"], ok_codes=[0, 1])
            lines = res.stdout.splitlines() if res.stdout else []
            existing_sub = None
            for line in lines:
                if " = " in line:
                    parts = line.split(" = ")
                    if len(parts) == 2 and parts[0].strip() == target:
                        existing_sub = parts[1].strip()
                        break

            if existing_sub != None:
                if existing_sub != substitute:
                    changed = True
                    if not ctx.check_mode:
                        res = ctx.run(["semanage", "fcontext", "-m", "-e", substitute, target], mutates=True)
                        if res.rc != 0:
                            fail("failed to modify fcontext equivalence: " + res.stderr)
                    msg = "fcontext equivalence updated"
                    if ctx.check_mode:
                        msg = "would update fcontext equivalence"
                    diff += "# Change to semanage file context path substitutions\n"
                    diff += "-%s = %s\n" % (target, existing_sub)
                    diff += "+%s = %s\n" % (target, substitute)
            else:
                changed = True
                if not ctx.check_mode:
                    res = ctx.run(["semanage", "fcontext", "-a", "-e", substitute, target], mutates=True)
                    if res.rc != 0:
                        fail("failed to add fcontext equivalence: " + res.stderr)
                msg = "fcontext equivalence added"
                if ctx.check_mode:
                    msg = "would add fcontext equivalence"
                diff += "# Addition to semanage file context path substitutions\n"
                diff += "+%s = %s\n" % (target, substitute)

    elif state == "absent":
        # Check if entry exists
        res = ctx.run(["semanage", "fcontext", "-l", "-C"], ok_codes=[0, 1])
        lines = res.stdout.splitlines() if res.stdout else []
        existing = None
        existing_sub = None
        for line in lines:
            parts = line.split()
            if len(parts) >= 3 and parts[0] == target and parts[1] == ftype_str:
                existing = line
                break

        if substitute == None:
            # Delete fcontext entry
            if existing != None:
                changed = True
                if not ctx.check_mode:
                    res = ctx.run(["semanage", "fcontext", "-d", "-f", ftype, target], mutates=True)
                    if res.rc != 0:
                        fail("failed to delete fcontext: " + res.stderr)
                msg = "fcontext deleted"
                if ctx.check_mode:
                    msg = "would delete fcontext"
                diff += "# Deletion to semanage file context mappings\n"
                diff += "-%s      %s\n" % (target, ftype_str)
        else:
            # Delete equivalence entry
            for line in lines:
                if " = " in line:
                    parts = line.split(" = ")
                    if len(parts) == 2 and parts[0].strip() == target:
                        existing_sub = parts[1].strip()
                        break

            if existing_sub != None:
                changed = True
                if not ctx.check_mode:
                    res = ctx.run(["semanage", "fcontext", "-d", "-e", existing_sub, target], mutates=True)
                    if res.rc != 0:
                        fail("failed to delete fcontext equivalence: " + res.stderr)
                msg = "fcontext equivalence deleted"
                if ctx.check_mode:
                    msg = "would delete fcontext equivalence"
                diff += "# Deletion to semanage file context path substitutions\n"
                diff += "-%s = %s\n" % (target, existing_sub)

    # Reload policy if requested and changed
    if changed and reload_policy and not ctx.check_mode:
        res = ctx.run(["semanage", "import"], mutates=True)
        if res.rc != 0:
            # Try alternate reload method if import fails
            res = ctx.run(["semodule", "-B"], mutates=True)
            if res.rc != 0:
                fail("failed to reload SELinux policy: " + res.stderr)

    if diff != "":
        return {"changed": changed, "msg": msg, "diff": {"prepared": diff}}
    return {"changed": changed, "msg": msg}
