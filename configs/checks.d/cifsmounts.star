def _parse_cifsmounts(string_table):
    section = {}
    for entry in string_table:
        if type(entry) == "list" and len(entry) >= 1:
            line = entry[0]
            data = None
            if line != None:
                if json.decode(line) == None:
                    data = None
                else:
                    data = json.decode(line)
            if data != None:
                mountpoint = str(data.get("mountpoint", ""))
                state = str(data.get("state", "unknown"))
                mount_seems_okay = bool(data.get("mount_seems_okay", False))
                usage_data = data.get("usage")
                usage = None
                if usage_data != None:
                    usage = {
                        "total_blocks": int(usage_data.get("total_blocks", 0)),
                        "free_blocks_su": int(usage_data.get("free_blocks_su", 0)),
                        "free_blocks": int(usage_data.get("free_blocks", 0)),
                        "blocksize": int(usage_data.get("blocksize", 0)),
                    }
                source = None if data.get("source") == None else str(data.get("source"))
                section[mountpoint] = {
                    "mountpoint": mountpoint,
                    "state": state,
                    "mount_seems_okay": mount_seems_okay,
                    "usage": usage,
                    "source": source,
                }
            else:
                if len(entry) >= 6:
                    last_two = entry[-2:]
                    if len(last_two) == 2 and last_two[0] == "Permission" and last_two[1] == "denied":
                        mountpoint = " ".join(entry[:-2])
                        section[mountpoint] = {
                            "mountpoint": mountpoint,
                            "state": "Permission denied",
                            "mount_seems_okay": False,
                            "usage": None,
                            "source": None,
                        }
                    else:
                        if len(entry) >= 6:
                            mountpoint = " ".join(entry[:-5])
                            state = entry[-5]
                            trailing = entry[-4:]
                            mount_seems_okay = (trailing == ["-", "-", "-", "-"])
                            usage = None
                            if trailing != ["-", "-", "-", "-"]:
                                usage = {
                                    "total_blocks": int(trailing[0]) if trailing[0].isdigit() else 0,
                                    "free_blocks_su": int(trailing[1]) if trailing[1].isdigit() else 0,
                                    "free_blocks": int(trailing[2]) if trailing[2].isdigit() else 0,
                                    "blocksize": int(trailing[3]) if trailing[3].isdigit() else 0,
                                }
                            section[mountpoint] = {
                                "mountpoint": mountpoint,
                                "state": state,
                                "mount_seems_okay": mount_seems_okay,
                                "usage": usage,
                                "source": None,
                            }
    return section

DEFAULT_NETWORK_FS_MOUNT_PARAMETERS = {
    "levels": (80.0, 90.0),
    "levels_low": (50.0, 70.0),
    "magic_normsize": 20.0,
    "show_levels": "onmagic",
    "show_reserved": True,
    "trend_range": 24,
    "trend_perfdata": True,
    "has_perfdata": False,
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["df", "-P"], mutates=False)
        mounts = []
        for line in res.stdout.splitlines():
            fields = line.split()
            if len(fields) >= 6 and fields[0] != "Filesystem":
                mountpoint = fields[5]
                mounts.append({
                    "item": mountpoint,
                    "params": DEFAULT_NETWORK_FS_MOUNT_PARAMETERS,
                    "metrics": ["used_percent"],
                })
        if len(mounts) == 0:
            mounts.append({
                "item": "",
                "params": DEFAULT_NETWORK_FS_MOUNT_PARAMETERS,
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d CIFS mounts" % len(mounts),
            "data": {"discovery": mounts},
        }
    
    item = params.get("item", "")
    res = ctx.run(["mount", "-l"], mutates=False)
    lines = res.stdout.splitlines()
    cifsmount = None
    for line in lines:
        if "cifs" in line.lower() or "smbfs" in line.lower():
            fields = line.split()
            if len(fields) >= 6:
                if "on" in fields:
                    idx = fields.index("on")
                    if len(fields) > idx + 1:
                        mountpoint = fields[idx + 1]
                        if mountpoint == item or (item == "" and mountpoint == ""):
                            cifsmount = {
                                "mountpoint": mountpoint,
                                "state": "ok",
                                "mount_seems_okay": True,
                                "usage": None,
                                "source": fields[0] if fields else None,
                            }
                elif len(fields) >= 4:
                    mountpoint = fields[2]
                    if mountpoint == item or (item == "" and mountpoint == ""):
                        cifsmount = {
                            "mountpoint": mountpoint,
                            "state": "ok",
                            "mount_seems_okay": True,
                            "usage": None,
                            "source": fields[0] if fields else None,
                        }
    
    if cifsmount:
        res_df = ctx.run(["df", "-P", cifsmount["mountpoint"]], mutates=False)
        lines_df = res_df.stdout.splitlines()
        if len(lines_df) >= 2:
            fields_df = lines_df[1].split()
            if len(fields_df) >= 5:
                total = int(fields_df[1]) * 1024.0
                used = int(fields_df[2]) * 1024.0
                free = int(fields_df[3]) * 1024.0
                percent_str = fields_df[4].rstrip("%")
                percent = int(percent_str) if percent_str.isdigit() else 0
                cifsmount["usage"] = {
                    "total_blocks": int(total / 1024.0),
                    "free_blocks": int(free / 1024.0),
                    "free_blocks_su": int(free / 1024.0),
                    "blocksize": 1024,
                }
    
    if not cifsmount:
        return {
            "changed": False,
            "msg": "no CIFS mount found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    state_str = cifsmount.get("state", "unknown")
    if state_str != "ok" and state_str != "OK":
        if state_str == "Permission denied":
            return {
                "changed": False,
                "msg": "State: Permission denied",
                "data": {"state": "CRIT", "metrics": {}, "details": ""},
            }
        elif state_str == "hanging" or state_str == "Hanging":
            return {
                "changed": False,
                "msg": "State: Hanging",
                "data": {"state": "CRIT", "metrics": {}, "details": ""},
            }
        else:
            return {
                "changed": False,
                "msg": "State: " + state_str.capitalize(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
    
    if cifsmount.get("mount_seems_okay", False):
        msg = "Mount seems OK"
        if cifsmount.get("source"):
            msg = "Source: " + str(cifsmount.get("source")) + ", Mount seems OK"
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }
    
    usage = cifsmount.get("usage")
    if not usage:
        return {
            "changed": False,
            "msg": "No usage data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    total_blocks = usage.get("total_blocks", 0)
    free_blocks = usage.get("free_blocks", 0)
    blocksize = usage.get("blocksize", 1024)
    MEGA = 1048576.0
    to_mb = blocksize / MEGA
    size_mb = total_blocks * to_mb
    free_mb = free_blocks * to_mb
    
    if size_mb <= 0 or free_mb < 0 or blocksize > 16.0 * MEGA:
        return {
            "changed": False,
            "msg": "Stale fs handle",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    
    used_mb = size_mb - free_mb
    used_percent = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0
    warn_percent, crit_percent = params.get("levels", (80.0, 90.0))
    
    state = "OK"
    if used_percent >= crit_percent:
        state = "CRIT"
    elif used_percent >= warn_percent:
        state = "WARN"
    
    msg_parts = []
    if cifsmount.get("source"):
        msg_parts.append("Source: " + str(cifsmount.get("source")))
    msg_parts.append("Size: %f MB" % size_mb)
    msg_parts.append("Used: %f MB" % used_mb)
    msg_parts.append("Free: %f MB" % free_mb)
    msg_parts.append("Usage: %f%%" % used_percent)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {
                "size": size_mb,
                "used": used_mb,
                "free": free_mb,
                "used_percent": used_percent,
            },
            "details": "",
        },
    }