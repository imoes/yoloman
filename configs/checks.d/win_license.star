# Constants for default parameters
DEFAULT_STATUS = ["Licensed", "Initial grace period"]
DEFAULT_EXPIRATION_WARN = 7 * 24 * 60 * 60  # 7 days in seconds
DEFAULT_EXPIRATION_CRIT = 14 * 24 * 60 * 60  # 14 days in seconds

# Regular expression to extract minutes from "X minute(s)" string
TIME_LEFT_RE = " minute"

def parse_win_license(string_table):
    parsed = {}
    for line in string_table:
        if len(line) == 0:
            continue
        
        if line.startswith("License:"):
            # Extract value after "License:"
            idx = line.find(":")
            if idx >= 0:
                parsed["License"] = line[idx+1:].strip()
        
        # Handle time remaining lines (various formats)
        if line.startswith("Time remaining:") or line.startswith("Timebased") or line.startswith("Volume"):
            idx = line.find(":")
            if idx >= 0:
                expiration = line[idx+1:].strip()
                parsed["expiration"] = expiration
                # Extract minutes using our simple pattern
                pos = expiration.find(TIME_LEFT_RE)
                if pos >= 0:
                    prefix = expiration[:pos].strip()
                    if prefix.isdigit():
                        time_left = int(prefix) * 60
                        parsed["expiration_time"] = time_left
    return parsed

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cmdb", "windows_license"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        
        # Parse agent output manually (no cmk plugins available in Starlark)
        section = parse_win_license(res.stdout.splitlines())
        
        if "License" in section:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
    
    # Check mode
    # Get agent data
    res = ctx.run(["cmdb", "windows_license"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve license data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    section = parse_win_license(res.stdout.splitlines())
    
    # Default parameters
    status_list = params.get("status", DEFAULT_STATUS)
    expiration_time = params.get("expiration_time", [DEFAULT_EXPIRATION_CRIT, DEFAULT_EXPIRATION_WARN])
    # Normalize expiration_time to warn/crit pair (Checkmk format is (crit, warn) for lower levels)
    if type(expiration_time) == "list" or type(expiration_time) == "tuple":
        if len(expiration_time) >= 2:
            crit = expiration_time[0]
            warn = expiration_time[1]
        else:
            crit = expiration_time[0]
            warn = expiration_time[0] // 2
    else:
        crit = expiration_time
        warn = expiration_time // 2
    
    # Check license status
    sw_license = section.get("License")
    if sw_license == None:
        return {
            "changed": False,
            "msg": "no license information found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    message = "Software is %s" % sw_license
    license_ok = sw_license in status_list
    
    if not license_ok:
        message += " Required: " + ", ".join(status_list)
    
    state = "OK" if license_ok else "CRIT"
    
    # Check expiration time
    time_left_str = section.get("expiration_time")
    time_left = None
    if time_left_str != None:
        # Guard against non-numeric values instead of try/except
        time_left_str_str = str(time_left_str)
        if time_left_str_str.isdigit() or (time_left_str_str.startswith("-") and time_left_str_str[1:].isdigit()):
            time_left = int(time_left_str)
    
    if time_left != None:
        if time_left < 0:
            state = "CRIT"
            message = "Licence expired %d seconds ago" % -time_left
        else:
            # Check levels (lower levels -> WARN if <= warn, CRIT if <= crit)
            if time_left <= crit:
                state = "CRIT"
                message = "Time until license expires: %d seconds" % time_left
            elif time_left <= warn:
                state = "WARN"
                message = "Time until license expires: %d seconds" % time_left
    
    return {
        "changed": False,
        "msg": message,
        "data": {
            "state": state,
            "metrics": {"expiration_time": time_left if time_left != None else 0},
            "details": ""
        }
    }
