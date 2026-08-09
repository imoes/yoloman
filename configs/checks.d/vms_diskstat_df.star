def _mb(raw):
    return int(raw) * 512 / (1024.0 * 1024.0)

def _parse_vms_diskstat(ctx):
    res = ctx.run(["cat", "/proc/vms_diskstat"], mutates=False)
    if res.rc != 0:
        return {}
    lines = res.stdout.splitlines()
    # Build section dict: label -> (label, size_mb, avail_mb, io_time)
    section = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        # Format: device: label size avail io_time
        # Device may have prefix like "$1$"
        if ":" not in parts[0]:
            continue
        device, label = parts[0].rstrip(":"), parts[1]
        size_str, avail_str, io_str = parts[2], parts[3], parts[4]
        # Keep last occurrence for repeated labels (reversed logic in source)
        size_mb = _mb(size_str)
        avail_mb = _mb(avail_str)
        section[label] = (label, size_mb, avail_mb, 0.0)
    return section

def main(ctx, params):
    if params.get("_discover"):
        section = _parse_vms_diskstat(ctx)
        # Discovery: one item per unique label (no grouping in this simple implementation)
        discovery = []
        for label in section:
            discovery.append({
                "item": label,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["used_percent"]
            })
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    section = _parse_vms_diskstat(ctx)
    if section.get(item) == None:
        return {
            "changed": False,
            "msg": "filesystem %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract volume data: (label, size_mb, avail_mb, io_time)
    label, size_mb, avail_mb, io_time = section.get(item)
    if size_mb == 0:
        used_percent = 0.0
    else:
        used_percent = 100.0 * (1.0 - (avail_mb / size_mb))
    
    # Get thresholds from params or defaults
    levels = params.get("levels", (80.0, 90.0))
    warn, crit = levels[0], levels[1]
    
    # Determine state
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg = "%s %f%% used" % (item, used_percent)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": ""
        }
    }