def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/local/sap"], mutates=False)
        lines = res.stdout.splitlines() if res.stdout.strip() else []
        sid_set = set()
        for line in lines:
            fields = line.split("\t")
            if len(fields) >= 5:
                sid = fields[0]
                path = fields[3]
                if path == "SAP CCMS Monitor Templates/Dialog Overview/Dialog Response Time/ResponseTime":
                    sid_set.add(sid)
        discovery_list = [{"item": sid, "params": {}, "metrics": []} for sid in sorted(sid_set)]
        return {"changed": False, "msg": "discovered %d dialog services" % len(discovery_list),
                "data": {"discovery": discovery_list}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/sap"], mutates=False)
    lines = res.stdout.splitlines() if res.stdout.strip() else []
    
    dialog = {}
    response_time_path = "SAP CCMS Monitor Templates/Dialog Overview/"
    
    for line in lines:
        fields = line.split("\t")
        if len(fields) >= 6:
            sid, state, _unused, path, reading, unit = fields[0], fields[1], fields[2], fields[3], fields[4], fields[5]
            # Determine state mapping
            state_int = int(state) if state.isdigit() else 0
            if state_int == 0 or state_int == 1:
                sap_state = "OK"
            elif state_int == 2:
                sap_state = "WARN"
            elif state_int == 3:
                sap_state = "CRIT"
            else:
                sap_state = "OK"
            
            if sid == item and path.startswith(response_time_path) and reading != "-":
                key = path.split("/")[-1]
                # Guard instead of try/except
                value = float(reading) if reading.replace(".", "", 1).replace("-", "", 1).isdigit() else 0.0
                dialog[key] = (value, unit)
    
    if not dialog:
        return {"changed": False, "msg": "no output about sap dialogs in agent output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    def perf_clean_key(s):
        return s.replace("(", "_").replace(")", "_").replace(" ", "_").replace(".", "_").rstrip("_")
    
    state = "OK"
    metrics = {}
    details_parts = []
    
    for key, (value, unit) in dialog.items():
        metric_name = perf_clean_key(key)
        metrics[metric_name] = value
        label = key
        unit_str = "" if unit == "-" else unit
        details_parts.append("%s: %f %s" % (label, value, unit_str))
    
    details_str = ", ".join(details_parts)
    return {"changed": False, "msg": details_str,
            "data": {"state": state, "metrics": metrics, "details": ""}}