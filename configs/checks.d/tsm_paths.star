def main(ctx, params):
    # Try to run dsmpath to get path information
    res = ctx.run(["dsmpath"], mutates=False)
    
    # If dsmpath is not found or fails, try alternative approach
    if res.rc != 0:
        # Try to use dsmc query path as fallback
        res = ctx.run(["dsmc", "query", "path"], mutates=False)
        if res.rc != 0:
            # If both fail, we return UNKNOWN
            return {
                "changed": False,
                "msg": "Cannot gather TSM paths data (dsmpath and dsmc query path failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
    
    # Parse the output: expect lines with path name, status, active status
    lines = res.stdout.splitlines()
    
    # Skip header lines
    data_lines = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Check if it looks like a header
        if stripped.lower().find("path name") >= 0 or stripped.lower().find("status") >= 0 or stripped.lower().find("active") >= 0:
            continue
        # Check if it's a separator line (dashes)
        if stripped.startswith("-"):
            continue
        data_lines.append(stripped)
    
    section = []
    for line in data_lines:
        parts = line.split()
        if len(parts) >= 3:
            path_name = parts[0]
            status = parts[1]
            active = parts[2]
            section.append([path_name, status, active])
    
    if params.get("_discover"):
        if len(section) > 0:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "discovered no services",
            "data": {"discovery": []},
        }
    
    # Check mode
    error_paths = []
    for item in section:
        if len(item) >= 3 and item[2].upper() == "YES":
            continue
        if len(item) >= 3:
            error_paths.append(item[0])
    
    if len(error_paths) > 0:
        return {
            "changed": False,
            "msg": "Paths with errors: %s" % ", ".join(error_paths),
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    
    if len(section) == 0:
        return {
            "changed": False,
            "msg": "No paths found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    return {
        "changed": False,
        "msg": "%d paths OK" % len(section),
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }