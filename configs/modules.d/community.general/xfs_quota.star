def main(ctx, params):
    # Required params
    mountpoint = params["mountpoint"]
    quota_type = params["type"]
    state = params.get("state", "present")

    # Optional params with defaults
    name = params.get("name")
    bhard = params.get("bhard")
    bsoft = params.get("bsoft")
    ihard = params.get("ihard")
    isoft = params.get("isoft")
    rtbhard = params.get("rtbhard")
    rtbsoft = params.get("rtbsoft")

    # Helper: human readable size to bytes
    def human_to_bytes(size_str):
        suffixes = {"b": 1, "k": 1024, "m": 1024*1024, "g": 1024*1024*1024, "t": 1024*1024*1024*1024}
        size_str = size_str.strip().lower()
        for suffix, mult in suffixes.items():
            if size_str.endswith(suffix):
                return int(float(size_str[:-len(suffix)]) * mult)
        return int(size_str)

    # Convert size params
    if bhard != None:
        bhard = human_to_bytes(bhard)
    if bsoft != None:
        bsoft = human_to_bytes(bsoft)
    if rtbhard != None:
        rtbhard = human_to_bytes(rtbhard)
    if rtbsoft != None:
        rtbsoft = human_to_bytes(rtbsoft)

    # Check mountpoint
    if not ctx.file_exists(mountpoint):
        fail("Path '%s' does not exist" % mountpoint)

    # Check if it's a mountpoint by reading /proc/mounts
    mounts_content = ctx.file_read("/proc/mounts")
    mp_info = None
    for line in mounts_content.splitlines():
        parts = line.split()
        if len(parts) == 6 and parts[1] == mountpoint and parts[2] == "xfs":
            opts = parts[3].split(",")
            mp_info = {"mntopts": opts}
            break

    if mp_info == None:
        fail("Path '%s' is not a mount point or not located on an xfs file system." % mountpoint)

    # Set type_arg and default name
    type_arg = ""
    quota_default = ""
    if quota_type == "user":
        type_arg = "-u"
        quota_default = "root"
        if name == None:
            name = quota_default
        # Check mount options for user quota
        valid_opts = ["uquota", "usrquota", "quota", "uqnoenforce", "qnoenforce"]
        has_quota = False
        for opt in mp_info["mntopts"]:
            if opt in valid_opts:
                has_quota = True
                break
        if not has_quota:
            fail("Path '%s' is not mounted with the uquota/usrquota/quota/uqnoenforce/qnoenforce option." % mountpoint)
        # Verify user exists
        if not ctx.file_exists("/etc/passwd"):
            fail("Cannot verify user '%s' exists - /etc/passwd not found" % name)
        else:
            passwd_content = ctx.file_read("/etc/passwd")
            found = False
            for line in passwd_content.splitlines():
                if line.startswith(name + ":"):
                    found = True
                    break
            if not found:
                fail("User '%s' does not exist." % name)

    elif quota_type == "group":
        type_arg = "-g"
        quota_default = "root"
        if name == None:
            name = quota_default
        # Check mount options for group quota
        valid_opts = ["gquota", "grpquota", "gqnoenforce"]
        has_quota = False
        for opt in mp_info["mntopts"]:
            if opt in valid_opts:
                has_quota = True
                break
        if not has_quota:
            fail("Path '%s' is not mounted with the gquota/grpquota/gqnoenforce option." % mountpoint)
        # Verify group exists
        if not ctx.file_exists("/etc/group"):
            fail("Cannot verify group '%s' exists - /etc/group not found" % name)
        else:
            group_content = ctx.file_read("/etc/group")
            found = False
            for line in group_content.splitlines():
                if line.startswith(name + ":"):
                    found = True
                    break
            if not found:
                fail("Group '%s' does not exist." % name)

    elif quota_type == "project":
        type_arg = "-p"
        quota_default = "#0"
        if name == None:
            name = quota_default
        # Check mount options for project quota
        valid_opts = ["pquota", "prjquota", "pqnoenforce"]
        has_quota = False
        for opt in mp_info["mntopts"]:
            if opt in valid_opts:
                has_quota = True
                break
        if not has_quota:
            fail("Path '%s' is not mounted with the pquota/prjquota/pqnoenforce option." % mountpoint)

        # Verify /etc/projects exists if name != default
        if name != quota_default:
            if not ctx.file_exists("/etc/projects"):
                fail("Path '/etc/projects' does not exist.")
            if not ctx.file_exists("/etc/projid"):
                fail("Path '/etc/projid' does not exist.")
            # Check if project is defined in /etc/projid
            projid_content = ctx.file_read("/etc/projid")
            found = False
            for line in projid_content.splitlines():
                if line.startswith(name + ":"):
                    found = True
                    break
            if not found:
                fail("Entry '%s' has not been defined in /etc/projid." % name)

        # Project state check (only if not default)
        if name != quota_default:
            cmd = ["xfs_quota", "-x", "-c", "project %s" % name, mountpoint]
            res = ctx.run(cmd)
            prj_set = True
            for line in res.stdout.splitlines():
                if "is not set" in line.lower():
                    prj_set = False
                    break
        else:
            prj_set = True

        if state == "present" and not prj_set:
            if ctx.check_mode:
                return {"changed": True, "msg": "would set project quota for %s" % name}
            else:
                cmd = ["xfs_quota", "-x", "-c", "project -s %s" % name, mountpoint]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    fail("Could not set project: " + res.stderr)

        elif state == "absent" and prj_set and name != quota_default:
            if ctx.check_mode:
                return {"changed": True, "msg": "would clear project quota for %s" % name}
            else:
                cmd = ["xfs_quota", "-x", "-c", "project -C %s" % name, mountpoint]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    fail("Failed to clear project quota: " + res.stderr)

    # Get current quota values
    def quota_report(used_type):
        if used_type == "b":
            used_arg = "-b"
        elif used_type == "i":
            used_arg = "-i"
        elif used_type == "rtb":
            used_arg = "-r"

        cmd = ["xfs_quota", "-x", "-c", "report %s %s" % (type_arg, used_arg), mountpoint]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("Could not get quota report for %s: %s" % (used_type, res.stderr))

        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) > 3 and parts[0] == name:
                soft = int(parts[2])
                hard = int(parts[3])
                if used_type == "b" or used_type == "rtb":
                    factor = 1024
                else:
                    factor = 1
                return (soft * factor, hard * factor)
        return (None, None)

    current_bsoft, current_bhard = quota_report("b")
    current_isoft, current_ihard = quota_report("i")
    current_rtbsoft, current_rtbhard = quota_report("rtb")

    # Handle absent state: set to 0
    if state == "absent":
        bhard = 0
        bsoft = 0
        ihard = 0
        isoft = 0
        rtbhard = 0
        rtbsoft = 0

    # Compare current vs desired
    limits_to_set = []
    result_data = {}

    if bsoft != None and bsoft != current_bsoft:
        limits_to_set.append("bsoft=%s" % bsoft)
        result_data["bsoft"] = bsoft

    if bhard != None and bhard != current_bhard:
        limits_to_set.append("bhard=%s" % bhard)
        result_data["bhard"] = bhard

    if isoft != None and isoft != current_isoft:
        limits_to_set.append("isoft=%s" % isoft)
        result_data["isoft"] = isoft

    if ihard != None and ihard != current_ihard:
        limits_to_set.append("ihard=%s" % ihard)
        result_data["ihard"] = ihard

    if rtbsoft != None and rtbsoft != current_rtbsoft:
        limits_to_set.append("rtbsoft=%s" % rtbsoft)
        result_data["rtbsoft"] = rtbsoft

    if rtbhard != None and rtbhard != current_rtbhard:
        limits_to_set.append("rtbhard=%s" % rtbhard)
        result_data["rtbhard"] = rtbhard

    if len(limits_to_set) == 0:
        return {
            "changed": False,
            "msg": "Quotas already set correctly",
            "xfs_quota": {
                "bsoft": current_bsoft,
                "bhard": current_bhard,
                "isoft": current_isoft,
                "ihard": current_ihard,
                "rtbsoft": current_rtbsoft,
                "rtbhard": current_rtbhard
            },
            "bsoft": result_data.get("bsoft"),
            "bhard": result_data.get("bhard"),
            "isoft": result_data.get("isoft"),
            "ihard": result_data.get("ihard"),
            "rtbsoft": result_data.get("rtbsoft"),
            "rtbhard": result_data.get("rtbhard")
        }

    # Apply changes
    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would update quotas"
        }

    if name == quota_default:
        cmd = ["xfs_quota", "-x", "-c", "limit %s -d %s" % (type_arg, " ".join(limits_to_set)), mountpoint]
    else:
        cmd = ["xfs_quota", "-x", "-c", "limit %s %s %s" % (type_arg, " ".join(limits_to_set), name), mountpoint]

    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("Could not set limits: " + res.stderr)

    return {
        "changed": True,
        "msg": "updated quotas",
        "xfs_quota": {
            "bsoft": current_bsoft,
            "bhard": current_bhard,
            "isoft": current_isoft,
            "ihard": current_ihard,
            "rtbsoft": current_rtbsoft,
            "rtbhard": current_rtbhard
        },
        "bsoft": result_data.get("bsoft"),
        "bhard": result_data.get("bhard"),
        "isoft": result_data.get("isoft"),
        "ihard": result_data.get("ihard"),
        "rtbsoft": result_data.get("rtbsoft"),
        "rtbhard": result_data.get("rtbhard")
    }
