def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/vms_users"], mutates=False, ok_codes=[0, 1])
        # Agent section <<<vms_users>>> not available -> no service
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["sessions"]}]},
        }

    # Check mode
    res = ctx.run(["cat", "/proc/vms_users"], mutates=False, ok_codes=[0, 1])
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no vms_users data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    infos = []
    num_sessions = 0
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) == 0:
            continue
        username = parts[0]
        # Pad with zeros if needed (max 5 columns: user + 4 session counts)
        session_values = []
        for p in parts[1:]:
            session_values.append(int(p) if p.isdigit() else 0)
        # Pad remaining columns with 0s
        session_values += [0] * (4 - len(session_values))
        interactive = session_values[0]  # first column after username is interactive

        if interactive > 0:
            num_sessions += interactive
            infos.append("%s: %d" % (username, interactive))

    if num_sessions > 0:
        summary = "Interactive users: " + ", ".join(infos)
        state = "OK"
    else:
        summary = "No interactive users"
        state = "OK"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"sessions": float(num_sessions)},
            "details": "",
        },
    }