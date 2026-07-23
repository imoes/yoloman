# Module-level constants
_DEFAULT_PARAMS = {
    "levels": (80.0, 90.0),
    "magic_norm": 0.0,
    "show_levels": "onwarn",
    "show_reserved": True,
    "show_timeleft": True,
    "show_used": True,
    "show_util": True,
    "trend_range": 24,
    "trend_perfdata": True,
    "invert_regex": False,
}

def _get_levels(params):
    # params.get("levels", (80.0, 90.0)) for usage percent
    levels = params.get("levels", (80.0, 90.0))
    if type(levels) == "list":
        # Convert list to tuple for easier handling
        levels = (float(levels[0]) if len(levels) > 0 and levels[0] != None else 80.0,
                  float(levels[1]) if len(levels) > 1 and levels[1] != None else 90.0)
    return levels

def _parse_aix_paging(lines):
    """Parse aix_paging section from command output (skip header, parse data)."""
    parsed = {}
    if len(lines) <= 1:
        return parsed
    
    for line in lines[1:]:
        parts = line.strip().split()
        if len(parts) < 8:
            continue
        
        # Parse: Page Space(0), Physical Volume(1), Volume Group(2), Size(3), %Used(4), Active(5), Auto(6), Type(7), Chksum(8)
        size_str = parts[3]
        if not size_str.endswith("MB"):
            continue
        size_part = size_str[:-2]
        size_mb = int(size_part) if size_part.isdigit() else 0
        
        usage_str = parts[4]
        usage = int(usage_str) if usage_str.isdigit() else 0
        
        paging_type_raw = parts[7]
        if paging_type_raw == "lv":
            paging_type = "logical volume"
        elif paging_type_raw == "nfs":
            paging_type = "NFS"
        else:
            paging_type = "unknown[" + paging_type_raw + "]"
        
        item = parts[0] + "/" + parts[1]
        parsed[item] = {
            "group": parts[2],
            "size_mb": size_mb,
            "usage_perc": usage,
            "active": parts[5],
            "auto": parts[6],
            "type_": paging_type,
        }
    
    return parsed

def _df_check_filesystem_single(value_store, item, total_mb, avail_mb, reserved_mb, levels, magic_norm, params):
    """
    Simplified version of df_check_filesystem_single logic for usage %.
    Returns (state, msg, metrics) for a single filesystem.
    """
    used_mb = total_mb - avail_mb
    used_percent = 0.0
    if total_mb > 0:
        used_percent = (used_mb / total_mb) * 100.0
    
    warn, crit = _get_levels(params)
    
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    
    msg_parts = []
    msg_parts.append("Size: %f MB" % total_mb)
    msg_parts.append("Used: %f MB" % used_mb)
    msg_parts.append("Avail: %f MB" % avail_mb)
    msg_parts.append("Used: %f%%" % used_percent)
    
    metrics = {"size": int(total_mb * 1024 * 1024), "used": int(used_mb * 1024 * 1024), "avail": int(avail_mb * 1024 * 1024), "used_percent": float(used_percent)}
    
    return state, ", ".join(msg_parts), metrics

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lsps", "-a"], mutates=False)
        lines = res.stdout.splitlines()
        section = _parse_aix_paging(lines)
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": _DEFAULT_PARAMS,
                "metrics": ["used_percent"]
            })
        return {"changed": False, "msg": "discovered %d page spaces" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Normal check mode: single item
    item = params.get("item", "")
    res = ctx.run(["lsps", "-a"], mutates=False)
    lines = res.stdout.splitlines()
    section = _parse_aix_paging(lines)
    
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "page space not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    total_mb = data["size_mb"]
    usage_percent = data["usage_perc"]
    used_percent = float(usage_percent)
    avail_mb = total_mb * (1 - usage_percent / 100.0)
    reserved_mb = 0
    
    state, msg, metrics = _df_check_filesystem_single({}, item, total_mb, avail_mb, reserved_mb, None, None, params)
    
    # Add detail info from aix_paging section
    detail_parts = ["Active: " + data["active"], "Auto: " + data["auto"], "Type: " + data["type_"]]
    msg = msg + ", " + ", ".join(detail_parts)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
