def _parse_quarantine_log(content):
    # Lines like: <timestamp>  Quarantine  <file/path>  <reason>  ...
    objs = []
    for line in content.split("\n"):
        s = line.strip()
        if not s:
            continue
        if s.startswith("#") or s.startswith(";"):
            continue
        # Heuristic: quarantine entries mention "Quarantine" or a path-like token
        if "Quarantine" in s or "quarantine" in s:
            objs.append(s)
    return objs

def main(ctx, params):
    log_path = params.get("log_path", "/var/log/symantec_av_quarantine.log")

    # Probe for the real thing: the product's quarantine log/report.
    st = ctx.stat(log_path)
    if st == None or not st.get("exists", False):
        if params.get("_discover"):
            return {"changed": False, "msg": "symantec AV quarantine log not found: " + log_path,
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False,
                "msg": "no symantec AV quarantine log found at " + log_path,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(log_path)
    objects = _parse_quarantine_log(content)

    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["objects"]},
                ], "host_labels": {}}}

    count = len(objects)
    if count > 0:
        state = "CRIT"
        summary = "%d objects in quarantine" % count
    else:
        state = "OK"
        summary = "No objects in quarantine"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"objects": count}, "details": ""}}