def main(ctx, params):
    # Extract parameters
    path = params["path"]
    src = params.get("src")
    fstype = params.get("fstype")
    opts = params.get("opts")
    dump = params.get("dump", "0")
    passno = params.get("passno", "0")
    state = params["state"]
    fstab = params.get("fstab")
    boot = params.get("boot", True)
    backup = params.get("backup", False)

    # Determine fstab path by OS
    facts = ctx.facts()
    os_family = facts.get("os_family", "").lower()
    is_solaris = facts.get("distribution", "").lower() == "sunos" or os_family == "solaris"

    if fstab == None:
        fstab = "/etc/vfstab" if is_solaris else "/etc/fstab"

    # OpenBSD does not support alternate fstab files
    if facts.get("distribution", "").lower() == "openbsd" and state != "ephemeral" and params.get("fstab") != None:
        fail("OpenBSD does not support alternate fstab files. Do not specify the fstab parameter for OpenBSD hosts")

    # Prepare args dict (mirroring original logic)
    args = {
        "name": path,
        "src": src if src != None else "",
        "fstype": fstype if fstype != None else "",
        "opts": opts if opts != None else ("-" if is_solaris else "defaults"),
        "dump": dump if dump != None else "0",
        "passno": passno if passno != None else "0",
        "fstab": fstab,
        "boot": "yes" if boot else "no",
    }

    # Adjust opts for Linux/BSD if noauto present (ignore boot)
    if not is_solaris and opts != None:
        opts_list = opts.split(",") if opts else []
        if "noauto" in opts_list:
            args["warnings"] = ["Ignore the 'boot' due to 'opts' contains 'noauto'."]
            args["boot"] = "yes"
        elif not boot:
            args["warnings"] = ["Ignore the 'boot' due to 'boot' is false."]
            if "defaults" in opts_list:
                args["boot"] = "yes"
            else:
                opts_list.append("noauto")
                args["opts"] = ",".join(opts_list)

    # Ensure fstab exists (except for ephemeral)
    if state != "ephemeral":
        if not ctx.file_exists(fstab):
            dirpath = fstab.rsplit("/", 1)[0]
            if not ctx.file_exists(dirpath):
                # Create directory path recursively using shell mkdir -p
                res = ctx.run(["mkdir", "-p", dirpath], mutates=True)
                if res.rc != 0:
                    fail("Failed to create directory %s: %s" % (dirpath, res.stderr))
            ctx.file_write(fstab, "")
            # Note: In check_mode, file_write returns whether it WOULD change

    changed = False
    msg = ""

    # State handling
    if state == "absent_from_fstab":
        # Remove entry from fstab only
        changed = _unset_mount(ctx, args)
        if changed and ctx.check_mode:
            return {"changed": True, "msg": "would remove entry from fstab"}
        msg = "removed entry from fstab"

    elif state == "absent":
        # Remove from fstab, unmount, and remove directory
        changed = _unset_mount(ctx, args)

        # Unmount if mounted
        if _is_mounted(ctx, path, src, fstype):
            res = ctx.run(["umount", path], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would unmount and remove"}
            if res.rc != 0:
                fail("Error unmounting %s: %s" % (path, res.stderr))

        # Remove directory if exists and empty
        if ctx.file_exists(path) and ctx.stat(path).get("is_dir", False):
            # Check if empty
            res = ctx.run(["ls", "-A", path])
            if res.rc == 0 and res.stdout.strip() == "":
                res = ctx.run(["rmdir", path], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would remove directory"}
            elif res.rc != 0 and res.rc != 1:
                # ls returns 1 if dir is empty, 0 otherwise; other errors fail
                fail("Error checking %s: %s" % (path, res.stderr))

        msg = "removed mount point and entry"

    elif state == "unmounted":
        if _is_mounted(ctx, path, src, fstype):
            res = ctx.run(["umount", path], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would unmount"}
            if res.rc != 0:
                fail("Error unmounting %s: %s" % (path, res.stderr))
            changed = True
            msg = "unmounted"
        else:
            msg = "already unmounted"

    elif state == "mounted":
        # Ensure mountpoint directory exists
        if not ctx.file_exists(path):
            if ctx.check_mode:
                return {"changed": True, "msg": "would create directory and mount"}
            # Create dirs recursively using shell
            dirpath = ""
            for part in path.strip("/").split("/"):
                dirpath = "/" + part if dirpath == "" else dirpath + "/" + part
                if not ctx.file_exists(dirpath):
                    ctx.run(["mkdir", "-p", dirpath], mutates=True)
            # Note: In check_mode, mkdir won't actually run; rely on _set_mount logic

        # Update fstab entry
        _, _, fstab_changed = _set_mount(ctx, args)
        changed = fstab_changed

        # Check if already mounted correctly
        if _is_mounted(ctx, path, src, fstype):
            if fstab_changed and not ctx.check_mode:
                # Remount needed
                res = _remount(ctx, args)
                if res != None:
                    return res
                changed = True
                msg = "mounted (entry changed and remounted)"
            else:
                msg = "already mounted"
        else:
            if not ctx.check_mode:
                res = ctx.run(_build_mount_cmd(args, is_solaris), mutates=True)
                if res.rc != 0:
                    fail("Error mounting %s: %s" % (path, res.stderr))
            changed = True
            msg = "mounted"

    elif state == "ephemeral":
        # Completely ignore fstab — mount directly
        if not ctx.file_exists(path):
            if ctx.check_mode:
                return {"changed": True, "msg": "would create directory and mount (ephemeral)"}
            ctx.run(["mkdir", "-p", path], mutates=True)

        # Check current mount status
        mounted_src = _get_mounted_src(ctx, path)
        if mounted_src != None:
            # Already mounted — check if same src or fail
            if mounted_src != src:
                fail("Ephemeral mount point is already mounted with a different source than the specified one. Failing in order to prevent an unwanted unmount or override operation.")
            # Same source — remount if opts differ or just refresh
            if opts != None and opts != "defaults":
                res = _remount(ctx, args)
                if res != None:
                    return res
            changed = True
            msg = "ephemeral mount (remounted)"
        else:
            # Not mounted — mount now
            if not ctx.check_mode:
                res = ctx.run(_build_mount_cmd(args, is_solaris), mutates=True)
                if res.rc != 0:
                    fail("Error mounting %s: %s" % (path, res.stderr))
            changed = True
            msg = "ephemeral mount (mounted)"

    elif state == "present":
        _, _, changed = _set_mount(ctx, args)
        msg = "configured in fstab" if changed else "already configured"

    elif state == "remounted":
        # Must have existing fstab entry; remount happens
        if not ctx.check_mode:
            res = _remount(ctx, args)
            if res != None:
                return res
        changed = True
        msg = "remounted"

    else:
        fail("Unsupported state: " + state)

    return {"changed": changed, "msg": msg}


def _escape_fstab(v):
    """Escape invalid characters in fstab fields."""
    if v == None:
        return ""
    if type(v) == "int":
        return str(v)
    return str(v).replace("\\", "\\134").replace(" ", "\\040").replace("&", "\\046")


def _set_mount(ctx, args):
    """Set/change a mount point in fstab; return (name, old_lines, changed)."""
    fstab = args["fstab"]
    name = _escape_fstab(args["name"])
    src = _escape_fstab(args["src"])
    fstype = _escape_fstab(args["fstype"])
    opts = _escape_fstab(args["opts"])
    dump = _escape_fstab(args["dump"])
    passno = _escape_fstab(args["passno"])
    boot = _escape_fstab(args["boot"])

    # Build new line based on OS
    facts = ctx.facts()
    is_solaris = facts.get("distribution", "").lower() == "sunos"
    if is_solaris:
        new_line = "%s - %s %s %s %s %s\n" % (src, name, fstype, passno, boot, opts)
    else:
        new_line = "%s %s %s %s %s %s\n" % (src, name, fstype, opts, dump, passno)

    # Read existing fstab
    if not ctx.file_exists(fstab):
        content = ""
    else:
        content = ctx.file_read(fstab)

    lines = content.split("\n")
    to_write = []
    found = False
    changed = False

    for line in lines:
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            to_write.append(line)
            continue

        # Parse line (handle optional fields on Linux)
        fields = stripped.split()
        if is_solaris:
            if len(fields) != 7:
                to_write.append(line)
                continue
            ld_src, dash, ld_name, ld_fstype, ld_passno, ld_boot, ld_opts = fields
        else:
            # Linux: 4-6 fields; default dump/passno to 0
            if len(fields) < 4 or len(fields) > 6:
                to_write.append(line)
                continue
            ld_src = fields[0]
            ld_name = fields[1]
            ld_fstype = fields[2]
            ld_opts = fields[3]
            ld_dump = fields[4] if len(fields) > 4 else "0"
            ld_passno = fields[5] if len(fields) > 5 else "0"

        # Match by name or by src for swap (name == none, fstype == swap)
        is_swap = (ld_name == "none" and ld_fstype == "swap")
        if ld_name != name or (args["src"] != None and is_swap and ld_src != src):
            to_write.append(line)
            continue

        # Found matching entry
        found = True
        # Compare fields
        if is_solaris:
            if ld_src != src or ld_fstype != fstype or ld_passno != passno or ld_boot != boot or ld_opts != opts:
                changed = True
                to_write.append(new_line)
            else:
                to_write.append(line)
        else:
            # Linux: compare all fields (dump/passno may be optional in source)
            ld_dump = fields[4] if len(fields) > 4 else "0"
            ld_passno = fields[5] if len(fields) > 5 else "0"
            if ld_src != src or ld_fstype != fstype or ld_opts != opts or ld_dump != dump or ld_passno != passno:
                changed = True
                to_write.append(new_line)
            else:
                to_write.append(line)

    if not found:
        changed = True
        to_write.append(new_line)

    # Write back if changed (but skip in check_mode)
    new_content = "\n".join(to_write)
    if changed and not ctx.check_mode:
        ctx.file_write(fstab, new_content)

    return (args["name"], [], changed)


def _unset_mount(ctx, args):
    """Remove mount entry from fstab; return True if changed."""
    fstab = args["fstab"]
    name = _escape_fstab(args["name"])
    src = _escape_fstab(args["src"])

    if not ctx.file_exists(fstab):
        return False

    content = ctx.file_read(fstab)
    lines = content.split("\n")
    to_write = []
    changed = False
    is_solaris = ctx.facts().get("distribution", "").lower() == "sunos"

    for line in lines:
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            to_write.append(line)
            continue

        fields = stripped.split()
        if is_solaris:
            if len(fields) != 7:
                to_write.append(line)
                continue
            ld_src, dash, ld_name, ld_fstype, ld_passno, ld_boot, ld_opts = fields
        else:
            if len(fields) != 6:
                to_write.append(line)
                continue
            ld_src, ld_name, ld_fstype, ld_opts, ld_dump, ld_passno = fields

        # Match by name or src (swap case)
        is_swap = (ld_name == "none" and ld_fstype == "swap")
        if ld_name != name or (args["src"] != None and is_swap and ld_src != src):
            to_write.append(line)
            continue

        # Remove matching line
        changed = True
        # Skip appending this line

    if changed:
        new_content = "\n".join(to_write)
        if not ctx.check_mode:
            ctx.file_write(fstab, new_content)

    return changed


def _build_mount_cmd(args, is_solaris):
    """Build mount command list."""
    cmd = ["mount"]
    if is_solaris:
        cmd += ["-F", args["fstype"]]
        if args["opts"] != "-":
            cmd += ["-o", args["opts"]]
        cmd += [args["src"], args["name"]]
    else:
        cmd += ["-t", args["fstype"]]
        if args["opts"] != "defaults":
            cmd += ["-o", args["opts"]]
        cmd += [args["src"], args["name"]]
    return cmd


def _build_remount_cmd(args, is_solaris):
    """Build remount command list."""
    cmd = ["mount"]
    if is_solaris:
        # Solaris doesn't have remount; use unmount + mount
        cmd = ["umount", args["name"]]
        return cmd
    # Linux/BSD remount
    if args["opts"] != "defaults":
        cmd += ["-o", "remount," + args["opts"]]
    else:
        cmd += ["-o", "remount"]
    cmd += [args["name"]]
    return cmd


def _remount(ctx, args):
    """Perform remount; return error result dict if failure, else None."""
    facts = ctx.facts()
    is_solaris = facts.get("distribution", "").lower() == "sunos"
    path = args["name"]

    if is_solaris:
        # Solaris: unmount then mount
        res = ctx.run(["umount", path], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would unmount and remount"}
        if res.rc != 0:
            fail("Error unmounting %s: %s" % (path, res.stderr))
        res = ctx.run(_build_mount_cmd(args, is_solaris), mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would mount"}
        if res.rc != 0:
            fail("Error mounting %s: %s" % (path, res.stderr))
        return None

    # Linux/BSD: try remount first
    cmd = _build_remount_cmd(args, is_solaris)
    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would remount"}
    if res.rc == 0:
        return None

    # Fallback: umount + mount (except BSDs with options, but keep simple)
    res = ctx.run(["umount", path], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would umount and mount"}
    if res.rc != 0:
        # If opts were specified, fail per original logic
        if args["opts"] != "defaults":
            fail("Options were specified with remounted, but the remount command failed. Failing in order to prevent an unexpected mount result.")
        fail("Error unmounting %s: %s" % (path, res.stderr))

    res = ctx.run(_build_mount_cmd(args, is_solaris), mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would mount"}
    if res.rc != 0:
        fail("Error mounting %s: %s" % (path, res.stderr))
    return None


def _find_in_list(lst, item):
    """Find item in list without using index() which triggers try/except error in Starlark."""
    for i in range(len(lst)):
        if lst[i] == item:
            return i
    return -1


def _is_mounted(ctx, path, src, fstype):
    """Check if path is mounted with optional src/fstype match."""
    facts = ctx.facts()
    os_family = facts.get("os_family", "").lower()
    is_linux = os_family == "linux"

    # Use /proc/self/mountinfo on Linux (like original module)
    if is_linux:
        if ctx.file_exists("/proc/self/mountinfo"):
            content = ctx.file_read("/proc/self/mountinfo")
            for line in content.split("\n"):
                if line.strip() == "":
                    continue
                fields = line.split()
                if len(fields) < 8:
                    continue
                # fields[-3] = fstype, fields[-2] = src, fields[4] = dest
                mount_dest = fields[4]
                mount_src = fields[-2]
                mount_fstype = fields[-3]
                if mount_dest == path:
                    if src == None and fstype == None:
                        return True
                    if src != None and fstype != None:
                        return mount_src == src and mount_fstype == fstype
                    if src != None:
                        return mount_src == src
                    if fstype != None:
                        return mount_fstype == fstype
            return False
        # Fallback: use mount -l
        res = ctx.run(["mount", "-l"])
        if res.rc != 0:
            return False
        mounts = res.stdout.strip().split("\n")
        for mnt in mounts:
            fields = mnt.split()
            if len(fields) < 5:
                continue
            # Format: <src> on <dest> type <fstype> ...
            if len(fields) < 4:
                continue
            # Try to parse "src on dest type fstype"
            idx_on = _find_in_list(fields, "on")
            idx_type = _find_in_list(fields, "type")
            if idx_on >= 0 and idx_type >= 0 and idx_on + 1 < len(fields) and idx_type + 1 < len(fields):
                mp_src = fields[0]
                mp_dst = fields[idx_on + 1]
                mp_fstype = fields[idx_type + 1]
                if mp_dst == path:
                    if src == None and fstype == None:
                        return True
                    if src != None and fstype != None:
                        return mp_src == src and mp_fstype == fstype
                    if src != None:
                        return mp_src == src
                    if fstype != None:
                        return mp_fstype == fstype
        return False

    # Non-Linux: use mount -l
    res = ctx.run(["mount", "-l"])
    if res.rc != 0:
        return False
    mounts = res.stdout.strip().split("\n")
    for mnt in mounts:
        fields = mnt.split()
        if len(fields) < 5:
            continue
        idx_on = _find_in_list(fields, "on")
        idx_type = _find_in_list(fields, "type")
        if idx_on >= 0 and idx_type >= 0 and idx_on + 1 < len(fields) and idx_type + 1 < len(fields):
            mp_src = fields[0]
            mp_dst = fields[idx_on + 1]
            mp_fstype = fields[idx_type + 1]
            if mp_dst == path:
                if src == None and fstype == None:
                    return True
                if src != None and fstype != None:
                    return mp_src == src and mp_fstype == fstype
                if src != None:
                    return mp_src == src
                if fstype != None:
                    return mp_fstype == fstype
    return False


def _get_mounted_src(ctx, path):
    """Return the source of the mounted filesystem on path, or None if not mounted."""
    facts = ctx.facts()
    os_family = facts.get("os_family", "").lower()
    is_linux = os_family == "linux"

    # Prefer Linux mountinfo
    if is_linux and ctx.file_exists("/proc/self/mountinfo"):
        content = ctx.file_read("/proc/self/mountinfo")
        for line in content.split("\n"):
            if line.strip() == "":
                continue
            fields = line.split()
            if len(fields) < 8:
                continue
            mount_dest = fields[4]
            if mount_dest == path:
                return fields[-2]  # src
        return None

    # Fallback: mount -l
    res = ctx.run(["mount", "-l"])
    if res.rc != 0:
        return None
    mounts = res.stdout.strip().split("\n")
    for mnt in mounts:
        fields = mnt.split()
        if len(fields) < 5:
            continue
        idx_on = _find_in_list(fields, "on")
        if idx_on >= 0 and idx_on + 1 < len(fields):
            mp_dst = fields[idx_on + 1]
            if mp_dst == path:
                return fields[0]
    return None
