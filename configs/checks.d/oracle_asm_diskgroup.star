def main(ctx, params):
    # Discovery mode: gather ASM diskgroups from asmcmd lsdg output
    if params.get("_discover"):
        res = ctx.run(["asmcmd", "lsdg", "-K"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "asmcmd failed: " + res.stderr,
                "data": {"discovery": []}
            }

        out = []
        lines = res.stdout.splitlines()
        for line in lines:
            if not line.strip():
                continue
            fields = line.split()
            if len(fields) < 12:
                continue

            # Extract diskgroup name (last field, strip trailing '/')
            dgname = fields[-1].rstrip("/")
            state = fields[0]

            # Skip if not MOUNTED or DISMOUNTED (per original logic)
            if state in ["MOUNTED", "DISMOUNTED"]:
                out.append({"item": dgname, "params": {}, "metrics": ["used_percent"]})

        return {
            "changed": False,
            "msg": "discovered %d diskgroups" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: verify one item
    item = params.get("item", "")
    res = ctx.run(["asmcmd", "lsdg", "-K", item], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "asmcmd failed for " + item + ": " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "diskgroup " + item + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse first data line
    fields = lines[1].split()
    if len(fields) < 12:
        return {
            "changed": False,
            "msg": "malformed asmcmd output for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    dgstate = fields[0]
    dgtype = fields[1]
    total_mb_str = fields[6]
    free_mb_str = fields[7]
    offline_disks_str = fields[10]
    voting_files = fields[9]

    # Convert numeric fields safely
    total = int(total_mb_str) if total_mb_str.isdigit() else 0
    free = int(free_mb_str) if free_mb_str.isdigit() else 0
    off_disks = int(offline_disks_str) if offline_disks_str.isdigit() else 0

    # Handle DISMOUNTED state
    if dgstate == "DISMOUNTED":
        return {
            "changed": False,
            "msg": "Diskgroup dismounted",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    # Determine redundancy factor
    dg_sizefactor = 1
    if dgtype == "NORMAL":
        dg_sizefactor = 2
    elif dgtype == "HIGH":
        dg_sizefactor = 3
    elif dgtype == "FLEX":
        dg_sizefactor = 1
    elif dgtype == "EXTERN":
        dg_sizefactor = 1

    # Apply factor
    usable_total = total // dg_sizefactor
    usable_free = free // dg_sizefactor

    # Calculate percentage used
    if usable_total == 0:
        used_percent = 0.0
    else:
        used_percent = (usable_total - usable_free) / usable_total * 100.0

    # Extract thresholds (Checkmk defaults from df_check_filesystem_single)
    warn_levels = params.get("levels", [80.0, 90.0])
    warn_percent = float(warn_levels[0])
    crit_percent = float(warn_levels[1])

    # Determine state
    state = "OK"
    if used_percent >= crit_percent:
        state = "CRIT"
    elif used_percent >= warn_percent:
        state = "WARN"

    # Build info text
    infotext = ""
    if dgtype != "":
        infotext = dgtype.lower() + " redundancy"

    # Offline disks
    if off_disks > 0:
        state = "CRIT"
        infotext = infotext + ", %d offline disks" % off_disks

    # Format message
    msg = "%s: %f%% used" % (item, used_percent)
    if infotext != "":
        msg = msg + ", " + infotext

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": ""
        }
    }