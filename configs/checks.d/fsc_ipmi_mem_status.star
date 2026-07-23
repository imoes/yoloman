# Map status codes to (State label, summary text)
# Note: Checkmk uses State.OK=0, State.WARN=1, State.CRIT=2, State.UNKNOWN=3
# We map directly to strings "OK", "WARN", "CRIT", "UNKNOWN" for Starlark return
_fsc_ipmi_mem_status_levels = [
    ("OK", "Empty slot"),
    ("OK", "Running"),
    ("WARN", "Reserved"),
    ("CRIT", "Error (module has encountered errors, but is still in use)"),
    ("CRIT", "Fail (module has encountered errors and is therefore disabled)"),
    ("CRIT", "Prefail (module exceeded the correctable errors threshold)"),
]

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ipmitool", "sdr", "type", "Memory"], mutates=False)
        lines = res.stdout.splitlines() if res.stdout else []
        out = []
        for line in lines:
            parts = line.split("|") if line else []
            if len(parts) < 3:
                continue
            name = parts[0].strip()
            status_raw = parts[2].strip()
            # Skip empty slots (status 00) and lines that start with 'E'
            if status_raw == "00" or name.startswith("E"):
                continue
            # Only include lines with valid status codes (00-05)
            if status_raw in ["00", "01", "02", "03", "04", "05"]:
                out.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d memory modules" % len(out),
            "data": {"discovery": out}
        }

    item = params.get("item", "")
    res = ctx.run(["ipmitool", "sdr", "type", "Memory"], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []

    # First pass: check for agent errors (lines starting with "E")
    for line in lines:
        if line and line.startswith("E"):
            return {
                "changed": False,
                "msg": "Error in agent plug-in output",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": ""
                }
            }

    # Second pass: find the specific item
    for line in lines:
        parts = line.split("|") if line else []
        if len(parts) < 3:
            continue
        name = parts[0].strip()
        status_raw = parts[2].strip()
        if name == item and status_raw in ["00", "01", "02", "03", "04", "05"]:
            status_idx = int(status_raw)
            state, summary = _fsc_ipmi_mem_status_levels[status_idx]
            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": ""
                }
            }

    return {
        "changed": False,
        "msg": "item %s not found" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }