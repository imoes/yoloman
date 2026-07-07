def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "enabled")
    activate_flag = params.get("activate", False)

    # Validate required_one_of: at least one of name or activate must be specified
    if not name and not activate_flag:
        fail("one of name or activate is required")

    # Check if awall is available
    res = ctx.run(["which", "awall"])
    if res.rc != 0:
        fail("awall binary not found")

    # Probe current enabled policies
    res = ctx.run(["awall", "list"])
    if res.rc != 0:
        fail("failed to list policies: " + res.stderr)
    output = res.stdout

    # Helper to determine if a policy is enabled
    def is_enabled(policy_name):
        for line in output.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == policy_name and parts[1] == "enabled":
                return True
        return False

    # Determine actions
    changes_needed = False
    msg_parts = []

    # Handle state changes for named policies
    if name:
        if state == "enabled":
            to_enable = []
            for pol in name:
                if not is_enabled(pol):
                    to_enable.append(pol)
            if to_enable:
                changes_needed = True
                msg_parts.append("enabled awall policy(ies): " + " ".join(to_enable))
        elif state == "disabled":
            to_disable = []
            for pol in name:
                if is_enabled(pol):
                    to_disable.append(pol)
            if to_disable:
                changes_needed = True
                msg_parts.append("disabled awall policy(ies): " + " ".join(to_disable))

    # If not in check_mode and there are state changes, perform them
    if changes_needed and not ctx.check_mode:
        if state == "enabled":
            to_enable = []
            for pol in name:
                if not is_enabled(pol):
                    to_enable.append(pol)
            if to_enable:
                res = ctx.run(["awall", "enable"] + to_enable, mutates=True)
                if res.rc != 0:
                    fail("failed to enable " + " ".join(to_enable) + ": " + res.stderr)
        elif state == "disabled":
            to_disable = []
            for pol in name:
                if is_enabled(pol):
                    to_disable.append(pol)
            if to_disable:
                res = ctx.run(["awall", "disable"] + to_disable, mutates=True)
                if res.rc != 0:
                    fail("failed to disable " + " ".join(to_disable) + ": " + res.stderr)

    # Handle activation (always reports changed unless in check_mode)
    activate_needed = activate_flag and not ctx.check_mode
    if activate_flag:
        if not ctx.check_mode:
            res = ctx.run(["awall", "activate", "--force"], mutates=True)
            if res.rc != 0:
                fail("could not activate new rules: " + res.stderr)

    # Build return result
    changed = changes_needed or activate_needed
    if changed:
        if not ctx.check_mode:
            msg = "; ".join(msg_parts)
            if activate_flag:
                if msg:
                    msg += "; "
                msg += "activated awall rules"
            else:
                if not msg:
                    msg = "activated awall rules"
            return {"changed": True, "msg": msg}
        else:
            msg = "would "
            if changes_needed:
                msg += "; ".join([p.replace("enabled", "enable").replace("disabled", "disable") for p in msg_parts])
            if activate_flag:
                if changes_needed:
                    msg += "; "
                msg += "activate awall rules"
            return {"changed": True, "msg": msg}
    else:
        if name:
            if state == "enabled":
                return {"changed": False, "msg": "policy(ies) already enabled"}
            else:
                return {"changed": False, "msg": "policy(ies) already disabled"}
        else:
            return {"changed": False, "msg": "awall rules already active"}
