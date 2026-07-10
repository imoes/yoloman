def main(ctx, params):
    path = params["path"]
    entry = params.get("entry")
    entity = params.get("entity", "")
    etype = params.get("etype")
    permissions = params.get("permissions")
    state = params.get("state", "query")
    follow = params.get("follow", True)
    default_flag = params.get("default", False)
    recursive = params.get("recursive", False)
    recalculate_mask = params.get("recalculate_mask", "default")
    use_nfsv4_acls = params.get("use_nfsv4_acls", False)

    # Platform check
    facts = ctx.facts()
    if facts.get("os_family", "").lower() not in ["debian", "redhat", "suse"]:
        fail("The acl module is only available on Linux distributions.")

    # Path existence check
    if not ctx.file_exists(path):
        fail("Path not found or not accessible.")

    # Validate state=query constraints
    if state == "query":
        if recursive:
            fail("'recursive' MUST NOT be set when 'state=query'.")
        if recalculate_mask in ["mask", "no_mask"]:
            fail("'recalculate_mask' MUST NOT be set to 'mask' or 'no_mask' when 'state=query'.")

    # Validate when entry is not provided
    if not entry:
        if state == "absent" and permissions:
            fail("'permissions' MUST NOT be set when 'state=absent'.")
        if state == "absent" and entity == "":
            fail("'entity' MUST be set when 'state=absent'.")
        if state in ["present", "absent"] and etype == None:
            fail("'etype' MUST be set when 'state=%s'." % state)

    # Validate when entry is provided
    if entry:
        if etype or entity or permissions != "":
            fail("'entry' MUST NOT be set when 'entity', 'etype' or 'permissions' are set.")
        if state == "present" and entry.count(":") not in [2, 3]:
            fail("'entry' MUST have 3 or 4 sections divided by ':' when 'state=present'.")
        if state == "absent" and entry.count(":") not in [1, 2]:
            fail("'entry' MUST have 2 or 3 sections divided by ':' when 'state=absent'.")
        if state == "query":
            fail("'entry' MUST NOT be set when 'state=query'.")

        # Parse entry: handle 'd' prefix for default ACLs
        parts = entry.split(":")
        default_from_entry = False
        if entry.lower().startswith("d"):
            default_from_entry = True
            parts.pop(0)

        if len(parts) == 2:
            parts.append(None)

        t, e, p = parts[0].lower(), parts[1], parts[2]

        if t.startswith("u"):
            etype = "user"
        elif t.startswith("g"):
            etype = "group"
        elif t.startswith("m"):
            etype = "mask"
        elif t.startswith("o"):
            etype = "other"
        else:
            fail("Invalid entity type in entry.")

        if default_from_entry:
            default_flag = True

        if e == "-":
            entity = ""
        else:
            entity = e

        if p == "-":
            permissions = ""
        else:
            permissions = p

    # Platform-specific restrictions
    if facts.get("distribution", "").lower() == "freebsd":
        if recursive:
            fail("recursive is not supported on that platform.")

    # Build entry string
    def build_entry(ent_type, ent, perms=None, nfsv4=False):
        if nfsv4:
            return ":".join([ent_type, ent, perms, "allow"]) if perms else ":".join([ent_type, ent, "", "allow"])
        if perms:
            return ent_type + ":" + ent + ":" + perms
        return ent_type + ":" + ent

    # Build command
    def build_cmd(mode):
        if mode == "set":
            cmd = ["setfacl", "-m", build_entry(etype, entity, permissions, use_nfsv4_acls)]
        elif mode == "rm":
            cmd = ["setfacl", "-x", build_entry(etype, entity, use_nfsv4_acls)]
        else:  # get
            cmd = ["getfacl", "--omit-header", "--absolute-names"]

        if recursive:
            cmd.append("--recursive")

        if recalculate_mask == "mask" and mode in ["set", "rm"]:
            cmd.append("--mask")
        elif recalculate_mask == "no_mask" and mode in ["set", "rm"]:
            cmd.append("--no-mask")

        if not follow:
            cmd.append("--physical")

        if default_flag:
            cmd.insert(1, "-d")

        cmd.append(path)
        return cmd

    # Run command
    def run_acl(cmd, check_rc=True):
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0 and check_rc:
            fail("ACL command failed: " + res.stderr)
        # Filter lines starting with '#'
        lines = [line.strip() for line in res.stdout.splitlines() if not line.startswith("#")]
        # Trim trailing empty line if present
        if lines and not lines[-1].strip():
            lines = lines[:-1]
        return lines

    # Check if ACL would change (Linux only)
    def acl_changed(cmd):
        test_cmd = cmd[:]  # copy list
        test_cmd.insert(1, "--test")
        res = ctx.run(test_cmd, mutates=False)
        for line in res.stdout.splitlines():
            if not line.endswith("*,*"):
                return True
        return False

    changed = False
    msg = ""

    if state == "present":
        cmd = build_cmd("set")
        changed = acl_changed(cmd)
        if changed and not ctx.check_mode:
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                changed = True
            elif res.rc != 0:
                fail("Failed to set ACL: " + res.stderr)
        msg = build_entry(etype, entity, permissions, use_nfsv4_acls) + " is present"

    elif state == "absent":
        cmd = build_cmd("rm")
        changed = acl_changed(cmd)
        if changed and not ctx.check_mode:
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                changed = True
            elif res.rc != 0:
                fail("Failed to remove ACL: " + res.stderr)
        msg = build_entry(etype, entity, use_nfsv4_acls) + " is absent"

    elif state == "query":
        msg = "current acl"

    # Get current ACL
    acl = run_acl(build_cmd("get"))

    return {"changed": changed, "msg": msg, "data": {"acl": acl}}
