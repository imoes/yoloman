def main(ctx, params):
    device = params.get("device")
    state = params.get("state", "available")
    force = params.get("force", False)
    recursive = params.get("recursive", False)
    attributes = params.get("attributes")

    force_opt = "-f" if force else ""
    recursive_opt = "-R" if recursive else ""

    # State aliases
    if state in ["available", "present"]:
        target_state = "available"
    elif state in ["removed", "absent", "defined"]:
        target_state = state
    else:
        fail("Unexpected state: " + state)

    result = {"changed": False, "msg": ""}

    # Helper: check device existence and state via lsdev -C -l <device>
    def check_device(dev_name):
        res = ctx.run(["lsdev", "-C", "-l", dev_name], mutates=False)
        if res.rc != 0:
            fail("Failed to run lsdev: " + res.stderr)
        if res.stdout:
            parts = res.stdout.strip().split()
            if len(parts) >= 2:
                return True, parts[1]
        return False, None

    # Helper: get attribute via lsattr -E -l <device> -a <attr>
    def get_attr(dev_name, attr_name):
        res = ctx.run(["lsattr", "-E", "-l", dev_name, "-a", attr_name], mutates=False)
        if res.rc == 255:
            return "" if attr_name in ["delalias4", "delalias6"] else None
        if res.rc != 0:
            fail("Failed to run lsattr for " + attr_name + ": " + res.stderr)
        parts = res.stdout.strip().split()
        if len(parts) >= 2:
            return parts[1]
        return None

    # Helper: run cfgmgr to discover/rescan device(s)
    def discover(dev_name):
        if dev_name and dev_name != "all":
            cmd = ["cfgmgr", "-l", dev_name]
        else:
            cmd = ["cfgmgr"]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return True, "would scan device"
        if res.rc != 0:
            fail("Failed to run cfgmgr: " + res.stderr)
        return True, res.stdout.strip()

    # Helper: rmdev to remove/define device
    def rmdev(dev_name, rm_opt, rec_opt, force_opt):
        if rm_opt:
            cmd = ["rmdev", "-l", dev_name, rec_opt, force_opt]
        else:
            cmd = ["rmdev", "-l", dev_name, rec_opt]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return True, "would " + ("remove" if rm_opt else "define") + " device"
        if res.rc != 0:
            fail("Failed to run rmdev: " + res.stderr)
        return True, res.stdout.strip()

    # Helper: chdev to set attributes
    def set_attr(dev_name, attr_dict, force_opt):
        changed_attrs = []
        unchanged_attrs = []
        invalid_attrs = []

        for attr_name, new_val in attr_dict.items():
            current = get_attr(dev_name, attr_name)
            if current == None:
                invalid_attrs.append(attr_name)
            elif current != new_val:
                if force_opt:
                    cmd = ["chdev", "-l", dev_name, "-a", attr_name + "=" + new_val, force_opt]
                else:
                    cmd = ["chdev", "-l", dev_name, "-a", attr_name + "=" + new_val]
                res = ctx.run(cmd, mutates=True)
                if res.skipped:
                    changed_attrs.append(attr_name)
                    continue
                if res.rc != 0:
                    fail("Failed to run chdev for " + attr_name + ": " + res.stderr)
                changed_attrs.append(attr_name)
            else:
                unchanged_attrs.append(attr_name)

        msg_parts = []
        if changed_attrs:
            msg_parts.append("Attributes changed: " + ",".join(changed_attrs) + ".")
        if unchanged_attrs:
            msg_parts.append("Attributes already set: " + ",".join(unchanged_attrs) + ".")
        if invalid_attrs:
            msg_parts.append("Invalid attributes: " + ",".join(invalid_attrs))

        msg = " ".join(msg_parts)
        changed = bool(changed_attrs)
        return changed, msg

    # Logic branch: state == 'available'
    if target_state == "available":
        if attributes:
            exists, dev_state = check_device(device)
            if exists:
                changed, msg = set_attr(device, attributes, force_opt)
                result["changed"] = changed
                result["msg"] = msg
            else:
                result["msg"] = "Device " + device + " does not exist."
        else:
            if device and device != "all":
                exists, dev_state = check_device(device)
                if exists:
                    changed, msg = discover(device)
                    result["changed"] = changed
                    result["msg"] = msg
                else:
                    result["msg"] = "Device " + device + " does not exist."
            else:
                changed, msg = discover(device)
                result["changed"] = changed
                result["msg"] = msg

    # Logic branch: removed, absent, defined
    elif target_state in ["removed", "absent", "defined"]:
        if not device:
            result["msg"] = "device is required to removed or defined state."
        else:
            exists, dev_state = check_device(device)
            if exists:
                if target_state == "defined" and dev_state == "Defined":
                    result["changed"] = False
                    result["msg"] = "Device " + device + " already in Defined"
                else:
                    rm_opt = "-d" if target_state in ["removed", "absent"] else ""
                    changed, msg = rmdev(device, rm_opt, recursive_opt, force_opt)
                    result["changed"] = changed
                    result["msg"] = msg
            else:
                result["msg"] = "Device " + device + " does not exist."

    else:
        fail("Unexpected state: " + target_state)

    return result
