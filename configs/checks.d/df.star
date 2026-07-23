# Constants defined at module top level
EXCLUDED_MOUNTPOINTS = ["/proc", "/sys", "/dev", "/run", "/sys/kernel/debug", "/sys/fs/cgroup"]

# Note: This check reads df output directly (same as Checkmk agent plugin).
# No SNMP or Checkmk agent required.

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: gather all filesystems and yield items
        res = ctx.run(["df", "-PkT"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "df command failed", "data": {"discovery": []}}
        
        out = []
        for line in res.stdout.splitlines()[1:]:
            f = line.split()
            if len(f) < 7:
                continue
            
            device = f[0]
            fs_type = f[1]
            size_kb = int(f[2])
            used_kb = int(f[3])
            avail_kb = int(f[4])
            use_percent_str = f[5].rstrip("%")
            use_percent = int(use_percent_str) if use_percent_str.isdigit() else 0
            mountpoint = f[6]
            
            # Skip excluded mountpoints
            if mountpoint in EXCLUDED_MOUNTPOINTS:
                continue
            
            # Skip docker local storage
            if mountpoint.startswith("/var/lib/docker/"):
                continue
            
            # Skip excluded filesystem types
            ignore_fs_types = ["tmpfs", "nfs", "smbfs", "cifs", "iso9660"]
            if fs_type in ignore_fs_types:
                continue
            
            # Create item name (mountpoint for default behavior)
            item = mountpoint
            
            # Prepare suggested parameters (same as Checkmk defaults)
            item_params = {"levels": (80.0, 90.0)}  # (warn_percent, crit_percent)
            
            out.append({
                "item": item,
                "params": item_params,
                "metrics": ["used_percent", "avail", "size"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode: examine one item (mountpoint)
    item = params.get("item", "")
    levels = params.get("levels", (80.0, 90.0))  # (warn_percent, crit_percent)
    
    res = ctx.run(["df", "-PkT", item], mutates=False)
    if res.rc != 0 or len(res.stdout.splitlines()) < 2:
        return {
            "changed": False,
            "msg": "no such mount: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse df line for the specific mountpoint
    fields = res.stdout.splitlines()[1].split()
    if len(fields) < 7:
        return {
            "changed": False,
            "msg": "parse error for mount: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    device = fields[0]
    fs_type = fields[1]
    size_kb = int(fields[2])
    used_kb = int(fields[3])
    avail_kb = int(fields[4])
    use_percent_str = fields[5].rstrip("%")
    use_percent = int(use_percent_str) if use_percent_str.isdigit() else 0
    
    # Convert to bytes for metric consistency (Checkmk expects bytes)
    size = size_kb * 1024
    used = used_kb * 1024
    avail = avail_kb * 1024
    
    # Calculate state against thresholds
    warn_percent = float(levels[0]) if len(levels) > 0 else 80.0
    crit_percent = float(levels[1]) if len(levels) > 1 else 90.0
    
    if use_percent >= crit_percent:
        state = "CRIT"
    elif use_percent >= warn_percent:
        state = "WARN"
    else:
        state = "OK"
    
    # Prepare message (Checkmk style)
    msg = "%s %d%% used" % (item, use_percent)
    
    # Build metrics dict (name -> number only)
    metrics = {
        "size": size,
        "used": used,
        "avail": avail,
        "used_percent": float(use_percent)
    }
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
