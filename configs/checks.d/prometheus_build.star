def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered Prometheus service", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    build_res = ctx.run(["curl", "-sS", "http://localhost:9090/api/v1/status/buildinfo"], mutates=False)
    targets_res = ctx.run(["curl", "-sS", "http://localhost:9090/api/v1/targets"], mutates=False)
    
    section = {}
    if build_res.stdout.strip():
        build_data = json.decode(build_res.stdout)
        if build_data.get("status") == "success":
            buildinfo = build_data.get("data", {}).get("buildinfo", {})
            version = buildinfo.get("prometheus_version")
            if version:
                section["version"] = [version]
    
    if targets_res.stdout.strip():
        targets_data = json.decode(targets_res.stdout)
        if targets_data.get("status") == "success":
            targets = targets_data.get("data", {}).get("activeTargets", [])
            total = len(targets)
            down = [t.get("labels", {}).get("instance", "") for t in targets if t.get("health") == "down"]
            if down:
                section["scrape_target"] = {"targets_number": total, "down_targets": down}
            else:
                section["scrape_target"] = {"targets_number": total}
    
    if not section:
        return {"changed": False, "msg": "Cannot retrieve Prometheus status data", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "OK"
    msg_parts = []
    
    if "version" in section:
        vers = section["version"]
        if len(vers) == 1:
            msg_parts.append("Version: " + vers[0])
        else:
            msg_parts.append("Version: multiple instances")
            msg_parts.append("Versions: " + ", ".join(vers))
    
    if "scrape_target" in section:
        st = section["scrape_target"]
        total = st.get("targets_number", 0)
        down = st.get("down_targets", [])
        up = total - len(down)
        if down:
            state = "WARN"
            msg_parts.append("Scrape Targets in up state: %d out of %d (Targets in down state: %s)" % (up, total, ", ".join(down)))
        else:
            msg_parts.append("Scrape Targets in up state: %d out of %d" % (up, total))
    
    if not msg_parts:
        msg_parts.append("No build information available")
    
    return {
        "changed": False,
        "msg": "; ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }