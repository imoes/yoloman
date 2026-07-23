# Constants for storage types
STORAGE_TYPE_FIXED_DISK = ".1.3.6.1.2.1.25.2.1.4"
STORAGE_TYPE_VCENTER = ".1.3.6.1.2.1.25.2.3.1.2.4"

# Excluded mountpoints (from Checkmk's df lib)
EXCLUDED_MOUNTPOINTS = [
    "/", "/proc", "/sys", "/dev", "/dev/pts", "/dev/shm",
    "/sys/kernel/debug", "/sys/kernel/security", "/run", "/run/lock",
    "/run/shm", "/run/user", "/dev/mqueue", "/sys/fs/cgroup"
]

def _pow(base, exp):
    result = 1
    for i in range(exp):
        result = result * base
    return result

def _to_mb(raw, unit_size):
    unscaled = int(raw)
    if unscaled < 0:
        unscaled = unscaled + _pow(2, 32)
    return unscaled * unit_size / 1048576.0

def fix_hr_fs_mountpoint(mp):
    mp = mp.replace("\\", "/")
    if "mounted on:" in mp:
        parts = mp.rsplit(":", 1)
        if len(parts) == 2:
            return parts[1].strip()
        return ""
    if "Label:" in mp:
        pos = mp.find("Label:")
        return mp[:pos].rstrip()
    return mp

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: gather HR filesystem data via SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.2.1.25.2.3.1"
        ], mutates=False)
        
        # Parse SNMP output into sections
        lines = res.stdout.splitlines()
        storage_entries = {}
        
        for line in lines:
            if "=" not in line:
                continue
            left, right = line.split("=", 1)
            left = left.strip()
            right = right.strip()
            
            # Extract OID and index: e.g., ".1.3.6.1.2.1.25.2.3.1.2.1"
            parts = left.split(".")
            if len(parts) < 12:
                continue
            col = int(parts[-2])
            idx = parts[-1]
            
            # Extract value: format "TYPE: value" or "value"
            if ":" in right:
                val = right.split(":", 1)[1].strip()
            else:
                val = right.strip()
            
            if idx not in storage_entries:
                storage_entries[idx] = {}
            storage_entries[idx][col] = val
        
        # Process entries
        discovered = []
        for idx, entry in storage_entries.items():
            hrtype = entry.get(2, "")
            hrdescr = entry.get(3, "")
            hrunits = entry.get(4, "")
            hrsize = entry.get(5, "")
            hrused = entry.get(6, "")
            
            # Skip non-fixed-disk types
            if hrtype not in [STORAGE_TYPE_FIXED_DISK, STORAGE_TYPE_VCENTER]:
                continue
            
            # Guard for parsing
            if not hrunits.isdigit() or not hrsize.isdigit() or not hrused.isdigit():
                continue
            
            unit_size = int(hrunits)
            size_mb = _to_mb(hrsize, unit_size)
            used_mb = _to_mb(hrused, unit_size)
            
            if size_mb == 0:
                continue
            
            mountpoint = fix_hr_fs_mountpoint(hrdescr)
            if not mountpoint or mountpoint in EXCLUDED_MOUNTPOINTS:
                continue
            
            discovered.append({
                "item": mountpoint,
                "params": {},
                "metrics": ["used_percent"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode: process one filesystem item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.2.1.25.2.3.1"
    ], mutates=False)
    
    # Parse SNMP output
    lines = res.stdout.splitlines()
    storage_entries = {}
    
    for line in lines:
        if "=" not in line:
            continue
        left, right = line.split("=", 1)
        left = left.strip()
        right = right.strip()
        
        parts = left.split(".")
        if len(parts) < 12:
            continue
        col = int(parts[-2])
        idx = parts[-1]
        
        if ":" in right:
            val = right.split(":", 1)[1].strip()
        else:
            val = right.strip()
        
        if idx not in storage_entries:
            storage_entries[idx] = {}
        storage_entries[idx][col] = val
    
    # Find matching item
    found = None
    for idx, entry in storage_entries.items():
        hrtype = entry.get(2, "")
        hrdescr = entry.get(3, "")
        hrunits = entry.get(4, "")
        hrsize = entry.get(5, "")
        hrused = entry.get(6, "")
        
        # Skip non-fixed-disk types
        if hrtype not in [STORAGE_TYPE_FIXED_DISK, STORAGE_TYPE_VCENTER]:
            continue
        
        # Guard for parsing
        if not hrunits.isdigit() or not hrsize.isdigit() or not hrused.isdigit():
            continue
        
        unit_size = int(hrunits)
        size_mb = _to_mb(hrsize, unit_size)
        used_mb = _to_mb(hrused, unit_size)
        
        if size_mb == 0:
            continue
        
        mountpoint = fix_hr_fs_mountpoint(hrdescr)
        if not mountpoint:
            continue
        
        if mountpoint == item:
            found = (size_mb, size_mb - used_mb)  # (total, avail)
            break
    
    if found == None:
        return {
            "changed": False,
            "msg": "filesystem not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    total_mb, avail_mb = found
    used_mb = total_mb - avail_mb
    
    # Calculate percentages
    if total_mb > 0:
        used_percent = (used_mb / total_mb) * 100.0
        avail_percent = (avail_mb / total_mb) * 100.0
    else:
        used_percent = 0.0
        avail_percent = 100.0
    
    # Get thresholds from params (Checkmk defaults)
    warn = params.get("levels", 80.0)
    if type(warn) == "list":
        if len(warn) > 0:
            warn = warn[0]
        else:
            warn = 80.0
    crit = params.get("levels", 90.0)
    if type(crit) == "list":
        if len(crit) > 0:
            crit = crit[0]
        else:
            crit = 90.0
    
    # Determine state
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Format message
    msg = "Size: %f MB, Used: %f MB (%f%%), Avail: %f MB (%f%%)" % (
        total_mb, used_mb, used_percent, avail_mb, avail_percent
    )
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "size": total_mb,
                "used": used_mb,
                "avail": avail_mb
            },
            "details": ""
        }
    }