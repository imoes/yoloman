def _get_multipath_count(ctx):
    res = ctx.run([
        "powershell", "-Command",
        "(Get-WmiObject -Class MPIO_DISK_SETTINGS -Namespace root\\WMI | Measure-Object).Count"
    ], mutates=False)
    
    if res.rc != 0:
        return None
    
    output = res.stdout.strip()
    if output == "":
        return None
    
    # Guard: only convert if output is digits (possibly negative)
    is_valid = True
    for c in output:
        if not (c >= "0" and c <= "9") and c != "-":
            is_valid = False
            break
    
    if not is_valid:
        return None
    
    return int(output)

def main(ctx, params):
    num_active = _get_multipath_count(ctx)
    
    if num_active == None:
        return {
            "changed": False,
            "msg": "multipath data unavailable",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Failed to query MPIO devices"
            }
        }
    
    # Default parameters from Checkmk source: active_paths=4
    active_paths_param = params.get("active_paths", 4)
    
    # DISCOVERY MODE
    if params.get("_discover"):
        if num_active > 0:
            return {
                "changed": False,
                "msg": "discovered 1 multipath device(s)",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {"active_paths": 4},
                            "metrics": []
                        }
                    ]
                }
            }
        else:
            return {
                "changed": False,
                "msg": "no multipath devices found",
                "data": {"discovery": []}
            }
    
    # CHECK MODE
    # Handle two cases: list (tuple) or integer
    if type(active_paths_param) == "list":
        if len(active_paths_param) != 3:
            return {
                "changed": False,
                "msg": "invalid multipath levels",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "Expected a tuple of 3 values for active_paths"
                }
            }
        
        num_paths = int(active_paths_param[0])
        warn_pct = float(active_paths_param[1])
        crit_pct = float(active_paths_param[2])
        
        warn_num = (warn_pct / 100.0) * num_paths
        crit_num = (crit_pct / 100.0) * num_paths
        
        if num_active < crit_num:
            state = "CRIT"
            summary = "Paths active: %d (warn/crit below %f/%f)" % (num_active, warn_num, crit_num)
        elif num_active < warn_num:
            state = "WARN"
            summary = "Paths active: %d (warn/crit below %f/%f)" % (num_active, warn_num, crit_num)
        else:
            state = "OK"
            summary = "Paths active: %d" % num_active
    else:
        expected = int(active_paths_param)
        if num_active < expected:
            state = "CRIT"
            summary = "Paths active: %d (crit below %d)" % (num_active, expected)
        elif num_active > expected:
            state = "WARN"
            summary = "Paths active: %d (warn at %d)" % (num_active, expected)
        else:
            state = "OK"
            summary = "Paths active: %d (expected: %d)" % (num_active, expected)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }