def main(ctx, params):
    if params.get("_discover"):
        mounts = ["/", "/home", "/var"]
        discovered = []
        for mount in mounts:
            res = ctx.run(["repquota", "-ugn", mount], mutates=False, ok_codes=[0, 1, 2])
            if res.rc in [1, 2] and ("No such device or address" in res.stderr or "No such file" in res.stderr):
                continue
            lines = res.stdout.splitlines()
            has_entries = False
            for line in lines:
                stripped = line.strip()
                if not stripped:
                    continue
                parts = stripped.split()
                if len(parts) >= 9:
                    owner = parts[0]
                    if owner.isalnum() or owner == "root" or owner == "nobody":
                        has_entries = True
                        break
            if has_entries:
                discovered.append({
                    "item": mount,
                    "params": {"user": True, "group": False},
                    "metrics": ["user_blocks_used", "user_files_used", "group_blocks_used", "group_files_used"]
                })
        return {
            "changed": False,
            "msg": "discovered %d quota-enabled mounts" % len(discovered),
            "data": {"discovery": discovered}
        }

    item = params.get("item", "")
    res = ctx.run(["repquota", "-ugn", item], mutates=False, ok_codes=[0, 1, 2])
    
    if res.rc == 2 and ("No such device or address" in res.stderr or "No such file" in res.stderr):
        return {
            "changed": False,
            "msg": "quota not enabled on %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    user_quota = None
    group_quota = None
    section = "none"
    
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(" Block "):
            section = "user"
            continue
        if stripped.startswith(" File "):
            section = "group"
            continue
        if stripped.startswith("---"):
            if section == "user":
                section = "group"
            continue
        parts = stripped.split()
        if len(parts) >= 9:
            owner = parts[0]
            if owner.isalnum() or owner == "root" or owner == "nobody":
                if section == "user":
                    used_blocks = int(parts[2]) * 1024 if parts[2].isdigit() else 0
                    soft_blocks = int(parts[3]) * 1024 if parts[3].isdigit() else 0
                    hard_blocks = int(parts[4]) * 1024 if parts[4].isdigit() else 0
                    used_files = int(parts[7]) if parts[7].isdigit() else 0
                    soft_files = int(parts[8]) if parts[8].isdigit() else 0
                    hard_files = int(parts[9]) if len(parts) > 9 and parts[9].isdigit() else 0
                    user_quota = {
                        "owner": owner,
                        "used_blocks": used_blocks,
                        "soft_blocks": soft_blocks,
                        "hard_blocks": hard_blocks,
                        "used_files": used_files,
                        "soft_files": soft_files,
                        "hard_files": hard_files
                    }
                    break
                elif section == "group":
                    group_quota = {
                        "owner": owner,
                        "used_blocks": int(parts[2]) * 1024 if parts[2].isdigit() else 0,
                        "soft_blocks": int(parts[3]) * 1024 if parts[3].isdigit() else 0,
                        "hard_blocks": int(parts[4]) * 1024 if parts[4].isdigit() else 0,
                        "used_files": int(parts[7]) if parts[7].isdigit() else 0,
                        "soft_files": int(parts[8]) if parts[8].isdigit() else 0,
                        "hard_files": int(parts[9]) if len(parts) > 9 and parts[9].isdigit() else 0
                    }

    user_enabled = params.get("user", False)
    group_enabled = params.get("group", False)
    
    if not user_enabled and not group_enabled:
        return {
            "changed": False,
            "msg": "Disabled quota checking",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    state = "OK"
    msg_parts = []
    metrics = {}
    
    if user_enabled and user_quota:
        if user_quota["soft_blocks"] > 0 or user_quota["hard_blocks"] > 0:
            used_b = user_quota["used_blocks"]
            soft_b = user_quota["soft_blocks"]
            hard_b = user_quota["hard_blocks"]
            if used_b >= hard_b:
                state = "CRIT"
                msg_parts.append("user block CRIT: %d/%d" % (used_b, hard_b))
            elif used_b >= soft_b:
                if state != "CRIT":
                    state = "WARN"
                msg_parts.append("user block WARN: %d/%d" % (used_b, soft_b))
            else:
                msg_parts.append("user block OK: %d/%d" % (used_b, hard_b))
            metrics["user_blocks_used"] = used_b
        if user_quota["soft_files"] > 0 or user_quota["hard_files"] > 0:
            used_f = user_quota["used_files"]
            soft_f = user_quota["soft_files"]
            hard_f = user_quota["hard_files"]
            if used_f >= hard_f:
                state = "CRIT"
                msg_parts.append("user files CRIT: %d/%d" % (used_f, hard_f))
            elif used_f >= soft_f:
                if state != "CRIT":
                    state = "WARN"
                msg_parts.append("user files WARN: %d/%d" % (used_f, soft_f))
            else:
                msg_parts.append("user files OK: %d/%d" % (used_f, hard_f))
            metrics["user_files_used"] = used_f

    if group_enabled and group_quota:
        if group_quota["soft_blocks"] > 0 or group_quota["hard_blocks"] > 0:
            used_b = group_quota["used_blocks"]
            soft_b = group_quota["soft_blocks"]
            hard_b = group_quota["hard_blocks"]
            if used_b >= hard_b:
                state = "CRIT"
                msg_parts.append("group block CRIT: %d/%d" % (used_b, hard_b))
            elif used_b >= soft_b:
                if state != "CRIT":
                    state = "WARN"
                msg_parts.append("group block WARN: %d/%d" % (used_b, soft_b))
            else:
                msg_parts.append("group block OK: %d/%d" % (used_b, hard_b))
            metrics["group_blocks_used"] = used_b
        if group_quota["soft_files"] > 0 or group_quota["hard_files"] > 0:
            used_f = group_quota["used_files"]
            soft_f = group_quota["soft_files"]
            hard_f = group_quota["hard_files"]
            if used_f >= hard_f:
                state = "CRIT"
                msg_parts.append("group files CRIT: %d/%d" % (used_f, hard_f))
            elif used_f >= soft_f:
                if state != "CRIT":
                    state = "WARN"
                msg_parts.append("group files WARN: %d/%d" % (used_f, soft_f))
            else:
                msg_parts.append("group files OK: %d/%d" % (used_f, hard_f))
            metrics["group_files_used"] = used_f

    if state == "OK" and not msg_parts:
        if user_enabled:
            msg_parts.append("user has no limits set")
        if group_enabled:
            msg_parts.append("group has no limits set")

    summary = ", ".join(msg_parts) if msg_parts else "quota enabled but no data"

    return {
        "changed": False,
        "msg": "%s: %s" % (item, summary),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }