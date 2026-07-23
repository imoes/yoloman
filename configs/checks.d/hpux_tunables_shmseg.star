# Module for Checkmk check: hpux_tunables_shmseg
# Read-only Starlark check module (discovery + check)

def main(ctx, params):
    # Data source: /var/adm/agent/plugins/hpux_tunables (agent-section format)
    # Read the agent section directly (colon-separated, 58 is ASCII for ':')
    content = ctx.file_read("/var/adm/agent/plugins/hpux_tunables") if ctx.file_exists("/var/adm/agent/plugins/hpux_tunables") else ""
    if content == None:
        content = ""
    
    # Parse section: map tunable name -> (usage, threshold)
    parsed = {}
    current_key = ""
    usage = 0
    for line in content.split("\n"):
        parts = line.split(":", 1)
        if len(parts) < 2:
            continue
        key = parts[0].strip()
        value = parts[1].strip()
        if key in ["Tunable", "Parameter"]:
            current_key = value
        elif key == "Usage":
            usage = int(value) if value.isdigit() else 0
        elif key == "Setting":
            threshold = int(value) if value.isdigit() else 0
            parsed[current_key] = (usage, threshold)

    # Discovery mode: enumerate items (only shmseg for this check)
    if params.get("_discover"):
        if "shmseg" in parsed:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"levels": [85.0, 90.0]}, "metrics": ["segments"]}]}
            }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    # Check mode: validate shmseg
    tunable = "shmseg"
    if not tunable in parsed:
        return {"changed": False, "msg": "shmseg not found in agent data", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    usage, threshold = parsed[tunable]
    if threshold == 0:
        perc = 0.0
    else:
        perc = float(usage) / float(threshold) * 100

    # Use Checkmk default thresholds from plugin
    warn, crit = params.get("levels", [85.0, 90.0])

    # Determine state
    if perc >= crit:
        state = "CRIT"
    elif perc >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Build message
    msg = "%f%% used (%d/%d segments)" % (perc, usage, threshold)

    # Build metrics dict (only the main metric, name matches Checkmk plugin)
    metrics = {"segments": usage}

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "(warn/crit at %f/%f)" % (warn, crit),
        },
    }