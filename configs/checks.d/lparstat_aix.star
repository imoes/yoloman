# ===== Starlark check module for lparstat_aix =====
# Read-only: only gathers data, never mutates the system

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check if lparstat is available and produces data
        res = ctx.run(["lparstat", "-A"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        lines = res.stdout.split("\n")
        if len(lines) < 4:
            # Agent needs update (per original logic)
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        # Check for utilization metrics
        header = lines[1].split() if len(lines) > 1 else []
        util_headers = []
        for h in header:
            name = h.lstrip("%")
            if name and name not in ("user", "sys", "idle", "wait"):
                util_headers.append(name)
        if util_headers:
            return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": util_headers}]}}
        else:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
    
    # Check mode for main lparstat service
    res = ctx.run(["lparstat", "-A"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "lparstat command failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.split("\n")
    if len(lines) < 4:
        return {"changed": False, "msg": "Please upgrade your AIX agent.", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    header = lines[1].split() if len(lines) > 1 else []
    values = lines[3].split() if len(lines) > 3 else []
    metrics = {}
    summary_parts = []
    
    for idx in range(len(header)):
        if idx < len(values):
            h = header[idx]
            v = values[idx]
            name = h.lstrip("%")
            if name and name not in ("user", "sys", "idle", "wait"):
                dot_count = 0
                is_number = True
                for c in v:
                    if c == ".":
                        dot_count += 1
                        if dot_count > 1:
                            is_number = False
                            break
                    elif not c.isdigit():
                        is_number = False
                        break
                if is_number:
                    val = float(v)
                    metrics[name] = val
                    summary_parts.append("%s: %f%%" % (name.title(), val))
    
    state = "OK"
    msg = ", ".join(summary_parts) if summary_parts else "No utilization metrics"
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": ""}}