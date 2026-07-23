def main(ctx, params):
    if params.get("_discover"):
        disks = []
        
        # Try to discover LSI RAID disks via sysfs
        res = ctx.run(["sh", "-c", "ls /sys/block/ 2>/dev/null"])
        for dev in res.stdout.splitlines():
            dev = dev.strip()
            if dev == "":
                continue
            
            # Check vendor and model for LSI/MegaRAID indicators
            res2 = ctx.run(["sh", "-c", "cat /sys/block/%s/device/vendor 2>/dev/null" % dev])
            vendor = res2.stdout.strip() if res2.rc == 0 else ""
            res2 = ctx.run(["sh", "-c", "cat /sys/block/%s/device/model 2>/dev/null" % dev])
            model = res2.stdout.strip() if res2.rc == 0 else ""
            
            # Check if this is an LSI RAID device
            if "LSI" in vendor.upper() or "MegaRAID" in vendor.upper() or "LSI" in model.upper() or "MegaRAID" in model.upper():
                disks.append({"item": dev, "params": {"expected_state": "ONL"}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d RAID disks" % len(disks),
                "data": {"discovery": disks}}
    
    # Check mode for single item
    item = params.get("item", "")
    expected_state = params.get("expected_state", "ONL")
    
    # Check if device exists
    res = ctx.run(["sh", "-c", "test -d /sys/block/%s/device" % item])
    if res.rc != 0:
        return {"changed": False, "msg": "Disk not present",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    # Try to get disk state from sysfs
    state = None
    res = ctx.run(["sh", "-c", "cat /sys/block/%s/device/state 2>/dev/null" % item])
    if res.rc == 0:
        raw_state = res.stdout.strip()
        # Extract state code like "ONL" from "Online(ONL)"
        if "(" in raw_state:
            state = raw_state.split("(")[-1].rstrip(")")
        else:
            state = raw_state
    
    if state == None:
        return {"changed": False, "msg": "Disk state cannot be determined",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state result
    if state != expected_state:
        return {"changed": False, "msg": "Disk has state '%s' (should be '%s')" % (state, expected_state),
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    return {"changed": False, "msg": "Disk has state '%s'" % state,
            "data": {"state": "OK", "metrics": {}, "details": ""}}