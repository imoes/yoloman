def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    share = params.get("share") or ""
    host = params.get("host") or ""
    workgroup = params.get("workgroup")
    ip_address = params.get("ip_address")
    port = params.get("port")
    auth_user = params.get("auth_user")
    auth_password = params.get("auth_password")
    warn_pct = params.get("warn_pct")
    crit_pct = params.get("crit_pct")
    timeout_s = int(params.get("timeout_s") or 30)

    unc = "//" + host + "/" + share
    argv = ["smbclient", unc, "-t", str(timeout_s)]

    if auth_user != None and auth_password != None:
        argv += ["-U", auth_user + "%" + auth_password]
    elif auth_user != None:
        argv += ["-U", auth_user, "-N"]
    else:
        argv += ["-N"]

    if workgroup != None:
        argv += ["-W", workgroup]

    if port != None:
        argv += ["-p", str(int(port))]

    if ip_address != None:
        argv += ["-I", ip_address]

    argv += ["-c", "fsinfo dskattr"]

    result = ctx.run(argv, ok_codes=[0, 1])

    if result.rc != 0:
        err = (result.stderr or result.stdout or "connection failed").strip()
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": "SMB connect failed: " + err}}

    block_size = 0
    total_blocks = 0
    free_blocks = 0

    for line in (result.stdout or "").split("\n"):
        s = line.strip()
        if s.startswith("Block Size:"):
            parts = s.split(":")
            if len(parts) > 1:
                block_size = int(parts[1].strip())
        elif s.startswith("Total Blocks:"):
            parts = s.split(":")
            if len(parts) > 1:
                total_blocks = int(parts[1].strip())
        elif s.startswith("Free Blocks:"):
            parts = s.split(":")
            if len(parts) > 1:
                free_blocks = int(parts[1].strip())

    if total_blocks == 0 or block_size == 0:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Could not parse disk info: " + (result.stdout or "").strip()}}

    total_bytes = total_blocks * block_size
    free_bytes = free_blocks * block_size
    used_bytes = total_bytes - free_bytes
    used_pct = int(used_bytes * 100 / total_bytes)
    free_gb = free_bytes / (1024 * 1024 * 1024)
    total_gb = total_bytes / (1024 * 1024 * 1024)

    state = "OK"
    problems = []

    if crit_pct != None and used_pct >= int(crit_pct):
        state = "CRIT"
        problems.append("%d%% used >= %d%%" % (used_pct, int(crit_pct)))
    elif warn_pct != None and used_pct >= int(warn_pct):
        state = "WARN"
        problems.append("%d%% used >= %d%%" % (used_pct, int(warn_pct)))

    detail = "SMB %s: %d%% used, %d GB free of %d GB" % (share, used_pct, int(free_gb), int(total_gb))
    if problems:
        detail += " | " + "; ".join(problems)

    return {
        "changed": False,
        "msg": state,
        "data": {
            "state": state,
            "metrics": {
                "used_pct": float(used_pct),
                "free_gb": free_gb,
                "total_gb": total_gb,
            },
            "details": detail,
        },
    }
