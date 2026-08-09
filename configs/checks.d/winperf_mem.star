def main(ctx, params):
    section_file = "/var/lib/yolo-agent/sections/winperf_mem"
    if not ctx.file_exists(section_file):
        return {
            "changed": False,
            "msg": "agent section 'winperf_mem' not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    content = ctx.file_read(section_file)
    lines = content.splitlines()
    
    if params.get("_discover"):
        if len(lines) > 1:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": ["mem_pages_rate"]
                        }
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {
                "discovery": []
            }
        }
    
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "agent section 'winperf_mem' is empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    parts0 = lines[0].split()
    if len(parts0) < 1:
        return {
            "changed": False,
            "msg": "invalid first line in winperf_mem section",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    this_time = 0.0
    if parts0[0].replace(".", "", 1).isdigit():
        this_time = float(parts0[0])
    else:
        return {
            "changed": False,
            "msg": "invalid timestamp in winperf_mem section",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    page_counter = 0
    found = False
    for line in lines:
        if not line.strip():
            continue
        line_parts = line.split()
        if len(line_parts) >= 2 and line_parts[0] == "36":
            if line_parts[1].lstrip("-").isdigit():
                page_counter = int(line_parts[1])
                found = True
                break
    
    if not found:
        return {
            "changed": False,
            "msg": "page counter (index 36) not found in winperf_mem section",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state_dir = "/var/lib/yolo-agent/state"
    state_file = state_dir + "/winperf_mem_pages"
    
    prev_time = None
    prev_counter = None
    if ctx.file_exists(state_file):
        state_content = ctx.file_read(state_file)
        state_lines = state_content.splitlines()
        if len(state_lines) >= 2:
            t_str = state_lines[0]
            c_str = state_lines[1]
            if t_str.replace(".", "", 1).isdigit() and c_str.lstrip("-").isdigit():
                prev_time = float(t_str)
                prev_counter = int(c_str)
    
    rate = 0.0
    if prev_time != None and prev_counter != None:
        if this_time > prev_time:
            rate = float(page_counter - prev_counter) / (this_time - prev_time)
        else:
            rate = 0.0
    else:
        return {
            "changed": False,
            "msg": "no previous state for rate calculation",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    ctx.file_write(state_file, str(this_time) + "\n" + str(page_counter))
    
    warn = 20.0
    crit = 50.0
    
    if params.get("pages_per_second") != None:
        threshold = params["pages_per_second"]
        if type(threshold) == "list":
            if len(threshold) >= 2:
                warn = float(threshold[0]) if type(threshold[0]) == "int" else 20.0
                crit = float(threshold[1]) if type(threshold[1]) == "int" else 50.0
    
    state = "OK"
    if rate >= crit:
        state = "CRIT"
    elif rate >= warn:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": "Pages/s: %f" % rate,
        "data": {
            "state": state,
            "metrics": {"mem_pages_rate": rate},
            "details": ""
        }
    }