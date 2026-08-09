def main(ctx, params):
    # This is an HP-UX tunables check for semmns (IPC Semaphores)
    item = params.get("item", "")
    levels = params.get("levels", (85.0, 90.0))
    warn = levels[0]
    crit = levels[1]
 
    # Discovery mode
    if params.get("_discover"):
        # Check if kctune is available (HP-UX)
        kctune_check = ctx.run(["kctune", "semmns"], mutates=False)
        if kctune_check.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
 
        # Check if ipcs is available
        ipcs_check = ctx.run(["ipcs", "-s"], mutates=False)
 
        # semmns tunable found - discover the service
        descr = "entries"
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"levels": levels}, "metrics": [descr]}
                ]
            },
        }
 
    # Check mode - check the semmns tunable
    descr = "entries"
 
    # Get the semmns setting from kctune
    kctune_res = ctx.run(["kctune", "semmns"], mutates=False)
    if kctune_res.rc != 0 or not kctune_res.stdout:
        return {
            "changed": False,
            "msg": "semmns tunable not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
 
    # Parse kctune output for semmns setting
    # kctune output format: "semmns              = 128" (or "semmns = 128")
    setting = 0
    for line in kctune_res.stdout.splitlines():
        if "semmns" in line:
            parts = line.split("=")
            if len(parts) >= 2:
                val_str = parts[1].strip()
                setting = int(val_str) if val_str.isdigit() else 0
            break
 
    if setting == 0:
        return {
            "changed": False,
            "msg": "semmns tunable not found or zero",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
 
    # Count current semaphores in use via ipcs
    ipcs_res = ctx.run(["ipcs", "-s"], mutates=False)
    usage = 0
    if ipcs_res.rc == 0:
        # ipcs -s output has a header line, then lines for each semaphore
        lines = ipcs_res.stdout.splitlines()
        # Skip header lines (typically 2 header lines on HP-UX)
        for line in lines[2:]:
            stripped = line.strip()
            if stripped and not stripped.startswith("------"):
                usage += 1
 
    # Calculate percentage
    perc = float(usage) / float(setting) * 100
 
    # Compute performance thresholds
    warn_perf = float(warn * setting / 100)
    crit_perf = float(crit * setting / 100)
 
    # Determine state
    state = "OK"
    if perc >= crit:
        state = "CRIT"
    elif perc >= warn:
        state = "WARN"
 
    summary = "%f%% used (%d/%d %s)" % (perc, usage, setting, descr)
    if perc >= crit:
        summary += " (warn/crit at %f/%f)" % (warn, crit)
    elif perc >= warn:
        summary += " (warn/crit at %f/%f)" % (warn, crit)
 
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"entries": usage},
            "details": "",
        },
    }