# Module: cephosdbluefs_wal
# Read-only Starlark check module for Ceph OSD WAL size and usage

# Constants
MIB = 1024.0 * 1024.0  # 1 MiB in bytes

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: enumerate all OSDs with WAL > 0
        res = ctx.run(["ceph", "osd", "bluefs", "show", "--format", "json"], mutates=False)
        if res.rc != 0:
            # Agent not available or command failed -> no items
            return {"changed": False, "msg": "discovered 0 WAL devices",
                    "data": {"discovery": []}}
        
        # Guard: if output is empty, skip parsing
        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 WAL devices",
                    "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        
        items = []
        for osdid, raw in data.items():
            bluefs = raw.get("bluefs")
            if bluefs == None:
                continue
            wal_total_bytes = bluefs.get("wal_total_bytes", 0)
            wal_total_mb = float(wal_total_bytes) / MIB
            if wal_total_mb > 0:
                # Suggested default params match Checkmk's FILESYSTEM_DEFAULT_PARAMS
                items.append({"item": osdid, "params": {}, "metrics": ["used_percent", "size", "used"]})
        
        return {"changed": False, "msg": "discovered %d WAL devices" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: analyze one specific WAL device
    item = params.get("item", "")
    res = ctx.run(["ceph", "osd", "bluefs", "show", "--format", "json"], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "failed to retrieve BlueFS data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Guard: if output is empty, report UNKNOWN
    if not res.stdout:
        return {"changed": False, "msg": "failed to parse BlueFS data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    
    if not item in data:
        return {"changed": False, "msg": "OSD %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    bluefs = data[item].get("bluefs")
    if bluefs == None:
        return {"changed": False, "msg": "OSD %s has no BlueFS info" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    wal_total_bytes = bluefs.get("wal_total_bytes", 0)
    wal_used_bytes = bluefs.get("wal_used_bytes", 0)
    wal_total_mb = float(wal_total_bytes) / MIB
    wal_used_mb = float(wal_used_bytes) / MIB
    
    if wal_total_mb <= 0:
        return {"changed": False, "msg": "OSD %s has no WAL device" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    wal_avail_mb = wal_total_mb - wal_used_mb
    used_percent = (wal_used_mb / wal_total_mb) * 100.0
    
    # Thresholds from params; use Checkmk's df.FILESYSTEM_DEFAULT_PARAMS defaults
    # These match Checkmk's default levels: levels=(80.0, 90.0), size=None, grow=None, shrink=None
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    
    # Determine state based on usage percentage
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build summary message in Checkmk style
    msg = "WAL %s: %f%% used (%f MB / %f MB)" % (item, used_percent, wal_used_mb, wal_total_mb)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "size": wal_total_mb,
                "used": wal_used_mb,
            },
            "details": "",
        },
    }
