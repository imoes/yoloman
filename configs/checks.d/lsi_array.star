def main(ctx, params):
    # Discovery mode: enumerate RAID arrays
    if params.get("_discover"):
        res = ctx.run(["dmidecode", "-t", "10"], mutates=False)
        # dmidecode output is not structured, so try alternative: ls /sys/class/scsi_host/
        # But checkmk.lsi_array expects data from agent section "lsi", which reads
        # /proc/driver/lsi/megaraid/*/stata_info or similar.
        # Since we can't rely on dmidecode for array info, check for common LSI sources:
        # 1. /proc/driver/lsi/megaraid/*/stata_info
        # 2. ls /sys/class/scsi_host/host*/device
        # 3. MegaCLI -LDInfo -Lall -aALL (not available), so use mpt-status or similar
        # 4. Check for /proc/scsi/megaraid or /sys/class/scsi_host
        
        # Most portable: check /proc/driver/lsi/megaraid/*/stata_info
        res = ctx.run(["bash", "-c", "cat /proc/driver/lsi/megaraid/*/stata_info 2>/dev/null || true"], mutates=False)
        out = []
        current_vol = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if line.startswith("VolumeID"):
                parts = line.split(":")
                if len(parts) >= 2:
                    current_vol = parts[1].strip()
            elif line.startswith("Statusofvolume") and current_vol != None:
                status = line.split(":", 1)[1].strip()
                # Expected format: Okay(OKY), Degraded(RBld), etc.
                out.append({"item": current_vol, "params": {}, "metrics": []})
                current_vol = None
        return {"changed": False, "msg": "discovered %d RAID arrays" % len(out),
                "data": {"discovery": out}}
    
    # Check mode: validate one array item
    item = params.get("item", "")
    # Read the same source as discovery
    res = ctx.run(["bash", "-c", "cat /proc/driver/lsi/megaraid/*/stata_info 2>/dev/null || true"], mutates=False)
    
    state = None
    current_vol = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.startswith("VolumeID"):
            parts = line.split(":")
            if len(parts) >= 2:
                current_vol = parts[1].strip()
        elif line.startswith("Statusofvolume") and current_vol == item:
            state = line.split(":", 1)[1].strip()
            break
    
    if state == None:
        return {"changed": False, "msg": "RAID volume %s not existing" % item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    # Check if state equals expected "Okay(OKY)"
    if state == "Okay(OKY)":
        return {"changed": False, "msg": "Status is '%s'" % state,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "Status is '%s'" % state,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}