def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["df", "-P"], mutates=False)
        discovery = []
        for line in res.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 6:
                continue
            mountpoint = parts[5]
            discovery.append({
                "item": mountpoint,
                "params": {
                    "levels": (80.0, 90.0),
                    "magic_normsize": 20,
                    "trend_range": 24,
                    "trend_pc": 5,
                    "show_levels": "on_warn",
                    "show_reserved": False,
                    "has_perfdata": False
                },
                "metrics": ["fs_used_percent", "fs_free", "fs_size", "growth", "trend"]
            })
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    item = params.get("item", "")
    res = ctx.run(["df", "-P", item], mutates=False)
    lines = res.stdout.splitlines()
    
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "mount not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    parts = lines[1].split()
    if len(parts) < 6:
        return {
            "changed": False,
            "msg": "malformed df output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    total_blocks_str = parts[1]
    used_blocks_str = parts[2]
    free_blocks_str = parts[3]
    
    total_blocks = int(total_blocks_str) if total_blocks_str.isdigit() else 0
    used_blocks = int(used_blocks_str) if used_blocks_str.isdigit() else 0
    free_blocks = int(free_blocks_str) if free_blocks_str.isdigit() else 0
    blocksize = 1024
    
    MEGA = 1048576.0
    size_mb = total_blocks * blocksize / MEGA if total_blocks > 0 else 0.0
    free_mb = free_blocks * blocksize / MEGA
    
    levels = params.get("levels", (80.0, 90.0))
    warn_percent = levels[0]
    crit_percent = levels[1]
    
    used_percent = (used_blocks / total_blocks) * 100 if total_blocks > 0 else 0.0
    
    if used_percent >= crit_percent:
        state = "CRIT"
    elif used_percent >= warn_percent:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Size: %f MB, Used: %f MB, Usage: %f%%" % (size_mb, size_mb - free_mb, used_percent)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "fs_used_percent": used_percent,
                "fs_free": free_mb,
                "fs_size": size_mb,
                "growth": 0.0,
                "trend": 0.0
            },
            "details": ""
        }
    }