def main(ctx, params):
    name = params["name"]
    snapshot = params.get("snapshot")
    description = params.get("description")
    options = params.get("options")
    mountpoint = params.get("mountpoint")
    state = params.get("state", "present")
    force = params.get("force", False)

    facts = ctx.facts()
    os_family = facts.get("os_family", "").lower()
    is_freebsd = os_family == "freebsd"

    def beadm_list():
        cmd = ["beadm", "list", "-H"]
        if "@" in name:
            cmd.append("-s")
        return ctx.run(cmd, mutates=False)

    def find_be_by_name(out):
        lines = out.splitlines() if out else []
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            if "@" in name:
                if is_freebsd:
                    full_name = parts[0].split("/")
                    if not full_name:
                        continue
                    be_name = full_name[-1]
                    if be_name == name:
                        return parts
                else:
                    parts_semicolon = line.split(";")
                    if parts_semicolon and parts_semicolon[0] == name:
                        return parts_semicolon
            else:
                if is_freebsd:
                    if parts[0] == name:
                        return parts
                else:
                    parts_semicolon = line.split(";")
                    if parts_semicolon and parts_semicolon[0] == name:
                        return parts_semicolon
        return None

    def exists():
        res = beadm_list()
        if res.rc == 0:
            return find_be_by_name(res.stdout) != None
        return False

    def is_activated():
        res = beadm_list()
        if res.rc != 0:
            return False
        line = find_be_by_name(res.stdout)
        if not line:
            return False
        if is_freebsd:
            # On FreeBSD, the active BE has 'R' flag in the second column (index 1)
            if len(line) > 1 and "R" in line[1]:
                return True
        else:
            # On Solaris, the active BE has 'R' flag in the third column (index 2)
            if len(line) > 2 and "R" in line[2]:
                return True
        return False

    def is_mounted():
        res = beadm_list()
        if res.rc != 0:
            return False
        line = find_be_by_name(res.stdout)
        if not line:
            return False
        if is_freebsd:
            # On FreeBSD, mounted BEs appear in column 3 (index 2); exclude '/' and '-'
            if len(line) > 2 and line[2] != '-' and line[2] != '/':
                return True
        else:
            # On Solaris, mountpoint is in column 4 (index 3)
            if len(line) > 3 and line[3]:
                return True
        return False

    def create_be():
        cmd = ["beadm", "create"]
        if snapshot:
            cmd.extend(["-e", snapshot])
        if not is_freebsd:
            if description:
                cmd.extend(["-d", description])
            if options:
                cmd.extend(["-o", options])
        cmd.append(name)
        return ctx.run(cmd, mutates=True)

    def destroy_be():
        cmd = ["beadm", "destroy", "-F", name]
        return ctx.run(cmd, mutates=True)

    def activate_be():
        cmd = ["beadm", "activate", name]
        return ctx.run(cmd, mutates=True)

    def mount_be():
        cmd = ["beadm", "mount", name]
        if mountpoint:
            cmd.append(mountpoint)
        return ctx.run(cmd, mutates=True)

    def unmount_be():
        cmd = ["beadm", "unmount"]
        if force:
            cmd.append("-f")
        cmd.append(name)
        return ctx.run(cmd, mutates=True)

    # Check current state
    be_exists = exists()
    be_mounted = is_mounted()
    be_activated = is_activated()

    changed = False
    msg = ""

    if state == "absent":
        if be_exists:
            if not be_mounted:
                if ctx.check_mode:
                    changed = True
                    msg = "would remove boot environment " + name
                else:
                    if is_freebsd and be_activated:
                        fail("Unable to remove active BE!")
                    res = destroy_be()
                    if res.rc != 0:
                        fail("Error while destroying BE: " + res.stderr)
                    changed = True
                    msg = "removed boot environment " + name
            else:
                fail("Unable to remove BE as it is mounted!")
        else:
            msg = "boot environment " + name + " does not exist"

    elif state == "present":
        if not be_exists:
            if ctx.check_mode:
                changed = True
                msg = "would create boot environment " + name
            else:
                res = create_be()
                if res.rc != 0:
                    fail("Error while creating BE: " + res.stderr)
                changed = True
                msg = "created boot environment " + name
        else:
            msg = "boot environment " + name + " already exists"

    elif state == "activated":
        if not be_activated:
            if ctx.check_mode:
                changed = True
                msg = "would activate boot environment " + name
            else:
                if is_freebsd and be_mounted:
                    fail("Unable to activate mounted BE!")
                res = activate_be()
                if res.rc != 0:
                    fail("Error while activating BE: " + res.stderr)
                changed = True
                msg = "activated boot environment " + name
        else:
            msg = "boot environment " + name + " already activated"

    elif state == "mounted":
        if not be_mounted:
            if ctx.check_mode:
                changed = True
                msg = "would mount boot environment " + name
            else:
                res = mount_be()
                if res.rc != 0:
                    fail("Error while mounting BE: " + res.stderr)
                changed = True
                msg = "mounted boot environment " + name
        else:
            msg = "boot environment " + name + " already mounted"

    elif state == "unmounted":
        if be_mounted:
            if ctx.check_mode:
                changed = True
                msg = "would unmount boot environment " + name
            else:
                res = unmount_be()
                if res.rc != 0:
                    fail("Error while unmounting BE: " + res.stderr)
                changed = True
                msg = "unmounted boot environment " + name
        else:
            msg = "boot environment " + name + " already unmounted"

    return {"changed": changed, "msg": msg}
