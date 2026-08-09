def main(ctx, params):
    if params.get("_discover"):
        # Probe for HP-UX kctune command first
        res = ctx.run(["kctune", "-l", "-q"], mutates=False)
        if res.rc != 0 or res.rc == 127:
            return {"changed": False, "msg": "no HP-UX tunables found", "data": {"discovery": []}}
        
        # Parse the kctune output to find nproc
        tunables = _parse_kctune(res.stdout)
        if "nproc" not in tunables:
            return {"changed": False, "msg": "nproc not found", "data": {"discovery": []}}
        
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "nproc", "params": {"levels": (90.0, 96.0)}, "metrics": ["nproc"]},
                ],
                "host_labels": {"cmk/hpux": "true"},
            },
        }
    
    # Check mode
    item = params.get("item", "nproc")
    if item != "nproc":
        return {"changed": False, "msg": "unsupported item: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Verify we're on HP-UX and kctune is available
    res = ctx.run(["kctune", "-l", "-q"], mutates=False)
    if res.rc != 0 or res.rc == 127:
        return {"changed": False, "msg": "kctune not available - not an HP-UX system",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    tunables = _parse_kctune(res.stdout)
    if "nproc" not in tunables:
        return {"changed": False, "msg": "nproc tunable not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    usage, threshold = tunables["nproc"]
    if threshold == 0:
        return {"changed": False, "msg": "nproc threshold is zero",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    perc = float(usage) / float(threshold) * 100
    levels = params.get("levels", (90.0, 96.0))
    warn = levels[0]
    crit = levels[1]
    
    state = "OK"
    if perc >= crit:
        state = "CRIT"
    elif perc >= warn:
        state = "WARN"
    
    summary = "%f%% used (%d/%d processes)" % (perc, usage, threshold)
    details = "warn/crit at %s/%s" % (str(warn), str(crit))
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"nproc": usage},
            "details": details,
        },
    }


def _parse_kctune(output):
    """Parse kctune -l -q output to extract tunable usage and setting."""
    result = {}
    lines = output.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        parts = line.split()
        if len(parts) >= 3:
            # Format: name usage setting
            tunable_name = parts[0]
            if parts[1].isdigit() and parts[2].isdigit():
                usage = int(parts[1])
                setting = int(parts[2])
                result[tunable_name] = (usage, setting)
        i += 1
    return result