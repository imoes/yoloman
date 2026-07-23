# Top-level constants for path state mapping
HPUX_PATHSTATES = {
    "ACTIVE": 0,
    "STANDBY": 1,
    "FAILED": 2,
    "UNOPEN": 3,
    "OPENING": 0,
    "CLOSING": 1,
}

def _format_path_status(pathcounts):
    parts = []
    for name, idx in HPUX_PATHSTATES.items():
        count = pathcounts[idx]
        if count > 0:
            parts.append("%d %s" % (count, name))
    return ", ".join(parts)

def _parse_multipath_data(ctx):
    res = ctx.run(["ioscan", "-fun", "dsf"], mutates=False)
    lines = res.stdout.splitlines()
    section = {}
    current_wwid = ""
    current_disk = ""
    current_paths = [0, 0, 0, 0]  # ACTIVE, STANDBY, FAILED, UNOPEN
    
    for line in lines:
        stripped = line.strip()
        # Look for "LUN PATH INFORMATION FOR LUN : ..." lines
        if stripped.startswith("LUN PATH INFORMATION FOR LUN :"):
            # Extract the path from the end of the line after the last ":"
            parts = stripped.split(" : ")
            if len(parts) >= 2:
                current_disk = parts[-1].strip()
            else:
                current_disk = ""
            current_paths = [0, 0, 0, 0]
            continue
        
        # Look for "World Wide Identifier(WWID)    = ..." lines
        if stripped.startswith("World Wide Identifier"):
            # Extract WWID - value after the last "="
            idx = stripped.rfind("=")
            if idx >= 0:
                wwid = stripped[idx+1:].strip()
                if current_paths != [0, 0, 0, 0]:  # only record if we found states
                    section[wwid] = (current_disk, list(current_paths))
            continue
        
        # Look for "State    = ..." lines
        if stripped.startswith("State"):
            idx = stripped.rfind("=")
            if idx >= 0:
                state = stripped[idx+1:].strip()
                if state in HPUX_PATHSTATES:
                    idx_state = HPUX_PATHSTATES[state]
                    current_paths[idx_state] += 1
    
    return section

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        section = _parse_multipath_data(ctx)
        items = []
        for wwid, (_disk, (active, standby, failed, unopen)) in section.items():
            if active + standby + failed >= 2:
                params_default = {"expected": [active, standby, failed, unopen]}
                items.append({"item": wwid, "params": params_default, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d multipath devices" % len(items),
            "data": {"discovery": items},
        }
    
    # Check mode
    item = params.get("item", "")
    section = _parse_multipath_data(ctx)
    
    if item not in section:
        return {
            "changed": False,
            "msg": "multipath item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    disk, pathcounts = section[item]
    expected = params.get("expected", [0, 0, 0, 0])
    
    # Check failed paths first
    if pathcounts[2] > 0:  # FAILED index
        summary = "%s: %d failed paths! (%s)" % (
            disk, pathcounts[2], _format_path_status(pathcounts)
        )
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    
    # Compare path counts
    if list(pathcounts) != expected:
        summary = (
            "%s: Invalid path status %s (should be %s)" % (
                disk,
                _format_path_status(pathcounts),
                _format_path_status(expected)
            )
        )
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }
    
    # All good
    summary = "%s: %s" % (disk, _format_path_status(pathcounts))
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }