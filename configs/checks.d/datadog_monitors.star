def main(ctx, params):
    # Helper to parse a JSON line safely — return None if invalid
    def _parse_json_line(line):
        # Guard: non-empty line and starts with { for object
        if not line or not line.strip():
            return None
        stripped = line.strip()
        if not stripped.startswith("{"):
            return None
        # Starlark's json.decode is available and will fail on invalid JSON,
        # but we must avoid try/except. Since we cannot catch the error,
        # we assume valid agent output. If the JSON is invalid, json.decode
        # will cause the runtime to abort — but Checkmk agent output is valid.
        return json.decode(stripped)

    # Discovery mode
    if params.get("_discover"):
        default_states = ["Alert", "Ignored", "No Data", "OK", "Skipped", "Unknown", "Warn"]
        states_discover = params.get("states_discover", default_states)
        
        data_file = "/var/lib/datadog_monitors.txt"
        if not ctx.file_exists(data_file):
            return {
                "changed": False,
                "msg": "discovered 0 monitors (data file missing)",
                "data": {"discovery": []},
            }
        
        content = ctx.file_read(data_file)
        lines = content.splitlines()
        items = []
        
        for line in lines:
            monitor_dict = _parse_json_line(line)
            if monitor_dict == None:
                continue
            name = monitor_dict.get("name")
            if name == None:
                continue
            overall_state = monitor_dict.get("overall_state", "Unknown")
            if overall_state in states_discover:
                items.append({
                    "item": name,
                    "params": {
                        "state_mapping": {
                            "Alert": 2,
                            "Ignored": 3,
                            "No Data": 0,
                            "OK": 0,
                            "Skipped": 3,
                            "Unknown": 3,
                            "Warn": 1,
                        },
                        "tags_to_show": [],
                    },
                    "metrics": [],
                })
        
        return {
            "changed": False,
            "msg": "discovered %d monitors" % len(items),
            "data": {"discovery": items},
        }
    
    # Check mode
    item = params.get("item", "")
    data_file = "/var/lib/datadog_monitors.txt"
    if not ctx.file_exists(data_file):
        return {
            "changed": False,
            "msg": "monitor '%s' not found (data file missing)" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    content = ctx.file_read(data_file)
    lines = content.splitlines()
    
    # Build section map
    section = {}
    for line in lines:
        monitor_dict = _parse_json_line(line)
        if monitor_dict == None:
            continue
        name = monitor_dict.get("name")
        if name == None:
            continue
        options = monitor_dict.get("options", {})
        thresholds = options.get("thresholds", {})
        tags = monitor_dict.get("tags", [])
        message = monitor_dict.get("message", "")
        overall_state = monitor_dict.get("overall_state", "Unknown")
        section[name] = {
            "state": overall_state,
            "message": message,
            "thresholds": thresholds,
            "tags": tags,
        }
    
    # Check requested item exists
    if not section.get(item):
        return {
            "changed": False,
            "msg": "monitor '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    monitor = section.get(item)
    datadog_state = monitor.get("state", "Unknown")
    
    # State mapping
    default_state_mapping = {
        "Alert": 2,
        "Ignored": 3,
        "No Data": 0,
        "OK": 0,
        "Skipped": 3,
        "Unknown": 3,
        "Warn": 1,
    }
    state_mapping = params.get("state_mapping", default_state_mapping)
    checkmk_state_code = state_mapping.get(datadog_state, 3)
    
    state = "UNKNOWN"
    if checkmk_state_code == 0:
        state = "OK"
    elif checkmk_state_code == 1:
        state = "WARN"
    elif checkmk_state_code == 2:
        state = "CRIT"
    
    msg = "Overall state: %s" % datadog_state
    details = monitor.get("message", "")
    if not details:
        details = "No message"
    
    # Thresholds
    thresholds = monitor.get("thresholds", {})
    if len(thresholds) > 0:
        threshold_parts = []
        for k in sorted(thresholds.keys()):
            v = thresholds.get(k)
            threshold_parts.append("%s: %s" % (str(k), str(v)))
        details = details + "\nDatadog thresholds: " + ", ".join(threshold_parts)
    
    # Tags
    tags_to_show = params.get("tags_to_show", [])
    tags = monitor.get("tags", [])
    matching_tags = []
    for tag in tags:
        for regex in tags_to_show:
            if tag.startswith(regex):
                matching_tags.append(tag)
                break
    
    if len(matching_tags) > 0:
        details = details + "\nDatadog tags: " + ", ".join(matching_tags)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }