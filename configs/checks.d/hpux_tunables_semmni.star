def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["/usr/sbin/ksym", "-n"], mutates=False)
        parsed = {}
        key = ""
        usage = 0
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("Tunable") or stripped.startswith("Parameter"):
                parts = stripped.split(":", 1)
                if len(parts) >= 2:
                    key = parts[1].strip()
            elif stripped.startswith("Usage"):
                parts = stripped.split(":", 1)
                if len(parts) >= 2 and parts[1].strip().isdigit():
                    usage = int(parts[1].strip())
            elif stripped.startswith("Setting"):
                parts = stripped.split(":", 1)
                if len(parts) >= 2 and parts[1].strip().isdigit():
                    threshold = int(parts[1].strip())
                    parsed[key] = (usage, threshold)
        # Checkmk check expects "semmni" specifically
        if "semmni" in parsed:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"levels": (85.0, 90.0)}, "metrics": ["semmni"]}]}
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }

    # Check mode
    res = ctx.run(["/usr/sbin/ksym", "-n"], mutates=False)
    parsed = {}
    key = ""
    usage = 0
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Tunable") or stripped.startswith("Parameter"):
            parts = stripped.split(":", 1)
            if len(parts) >= 2:
                key = parts[1].strip()
        elif stripped.startswith("Usage"):
            parts = stripped.split(":", 1)
            if len(parts) >= 2 and parts[1].strip().isdigit():
                usage = int(parts[1].strip())
        elif stripped.startswith("Setting"):
            parts = stripped.split(":", 1)
            if len(parts) >= 2 and parts[1].strip().isdigit():
                threshold = int(parts[1].strip())
                parsed[key] = (usage, threshold)

    if "semmni" not in parsed:
        return {
            "changed": False,
            "msg": "semmni not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    usage, threshold = parsed["semmni"]
    perc = float(usage) / float(threshold) * 100
    warn, crit = params.get("levels", (85.0, 90.0))
    warn_perf = float(warn * threshold / 100)
    crit_perf = float(crit * threshold / 100)

    state = "CRIT" if perc > crit else ("WARN" if perc > warn else "OK")
    summary = "%f%% used (%d/%d semaphore_ids)" % (perc, usage, threshold)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"semmni": usage},
            "details": ""
        }
    }