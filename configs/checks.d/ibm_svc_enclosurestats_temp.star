def main(ctx, params):
    # Read the agent section data from the host
    # The Checkmk plugin parses <<<ibm_svc_enclosurestats:sep(58)>>>
    # which is colon-separated: enclosure_id:stat_name:current:peak:peak_time
    res = ctx.run(["cat", "/var/lib/check-mk-agent/spool/ibm_svc_enclosurestats"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "agent section not found", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the colon-separated lines into a dict of enclosures
    section = {}
    header = ["enclosure_id", "stat_name", "stat_current", "stat_peak", "stat_peak_time"]
    for line in res.stdout.splitlines():
        if not line:
            continue
        if " command not found" in line:
            continue
        fields = line.split(":")
        if len(fields) < 5:
            continue
        # Skip header lines
        if fields[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = fields
            continue
        if len(fields) != len(header):
            continue
        # Guard instead of try/except: parse only if numeric
        stat_current_str = fields[2]
        stat_current = int(stat_current_str) if stat_current_str.isdigit() else None
        if stat_current == None:
            continue
        # Use dict per enclosure_id
        enclosure_id = fields[0]
        stat_name = fields[1]
        if section.get(enclosure_id) == None:
            section[enclosure_id] = {}
        section[enclosure_id][stat_name] = stat_current
    
    # Discovery mode: enumerate enclosures with temp_c data
    if params.get("_discover"):
        items = []
        for enclosure_id, data in section.items():
            if data.get("temp_c") != None:
                items.append({
                    "item": enclosure_id,
                    "params": {"levels": [35.0, 40.0]},  # Checkmk default: (35.0, 40.0)
                    "metrics": ["temperature"]
                })
        return {"changed": False, "msg": "discovered %d enclosures" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: process single item
    item = params.get("item", "")
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "enclosure not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if data.get("temp_c") == None:
        return {"changed": False, "msg": "no temperature data for enclosure",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp_c = data["temp_c"]
    # Get levels from params (default: (35.0, 40.0) per Checkmk plugin)
    levels = params.get("levels", [35.0, 40.0])
    warn = levels[0]
    crit = levels[1]
    
    # Determine state: OK < warn <= CRIT
    if temp_c >= crit:
        state = "CRIT"
    elif temp_c >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {"changed": False, "msg": "Temperature: %f C" % temp_c,
            "data": {
                "state": state,
                "metrics": {"temperature": temp_c},
                "details": ""
            }}