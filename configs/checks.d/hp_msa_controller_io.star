def main(ctx, params):
    # Discovery mode: enumerate controllers from hp_msa_controller data
    if params.get("_discover"):
        # Read the controller data via snmpwalk (hp_msa uses SNMP)
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.232.36.1.1.1"  # hpMsaChassisObject
        ], mutates=False)
        
        # Parse OID -> controller mapping: hpMsaControllerName
        # OIDs: .1.3.6.1.4.1.232.36.1.1.1.2.x = hpMsaControllerName
        controllers = []
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            # Extract index from OID like .1.3.6.1.4.1.232.36.1.1.1.2.1
            if ".2." in oid_val:
                idx_str = oid_val.rsplit(".", 1)[1]
                if idx_str.isdigit():
                    controllers.append(int(idx_str))
        
        # Build discovery list: one item per controller index ("" means single-service)
        out = []
        for idx in controllers:
            out.append({
                "item": str(idx),
                "params": {
                    "levels": (80.0, 90.0)  # Checkmk diskstat default: warn=80%, crit=90%
                },
                "metrics": ["read_throughput", "write_throughput"]
            })
        return {
            "changed": False,
            "msg": "discovered %d controllers" % len(controllers),
            "data": {"discovery": out}
        }

    # Check mode: one item (controller index)
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Query controller data: .1.3.6.1.4.1.232.36.1.1.1.1.x (hpMsaControllerDataReadNumeric)
    # and .1.3.6.1.4.1.232.36.1.1.1.2.x (hpMsaControllerDataWrittenNumeric)
    read_oid = ".1.3.6.1.4.1.232.36.1.1.1.1." + item
    write_oid = ".1.3.6.1.4.1.232.36.1.1.1.2." + item
    
    # snmpget for read throughput
    res_read = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, read_oid
    ], mutates=False)
    read_val = None
    for line in res_read.stdout.splitlines():
        if line.find(" = ") != -1:
            val_str = line.strip().split(" = ")[1].strip()
            # Value is typically Counter64; extract numeric part
            if val_str.startswith("Counter64:"):
                val_part = val_str.split(":", 1)[1].strip()
                if val_part.isdigit():
                    read_val = float(val_part)
    
    # snmpget for write throughput
    res_write = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, write_oid
    ], mutates=False)
    write_val = None
    for line in res_write.stdout.splitlines():
        if line.find(" = ") != -1:
            val_str = line.strip().split(" = ")[1].strip()
            if val_str.startswith("Counter64:"):
                val_part = val_str.split(":", 1)[1].strip()
                if val_part.isdigit():
                    write_val = float(val_part)
    
    # If either read or write data is missing, return UNKNOWN
    if read_val == None or write_val == None:
        return {
            "changed": False,
            "msg": "no data for controller %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Compute rates: since we only have one snapshot, use elapsed time = 1 sec for rate
    # For simplicity, treat absolute bytes as rates (bytes/sec) for this single-sample case
    # We report MB/s: bytes -> MB
    read_mbs = read_val / 1024.0 / 1024.0
    write_mbs = write_val / 1024.0 / 1024.0
    
    # Apply default thresholds (MB/s levels)
    # Checkmk default: warn=80, crit=90 MB/s (from diskstat.DEFAULT_LEVELS)
    warn = params.get("levels", (80.0, 90.0))
    warn_val = 80.0
    crit_val = 90.0
    if type(warn) == "list":
        warn_val = warn[0] if len(warn) > 0 else 80.0
        crit_val = warn[1] if len(warn) > 1 else 90.0
    
    # Determine state based on read+write combined throughput (MB/s)
    total_mbs = read_mbs + write_mbs
    state = "CRIT" if total_mbs >= crit_val else ("WARN" if total_mbs >= warn_val else "OK")
    
    # Build summary message
    msg = "Controller %s: %f MB/s (read: %f, write: %f)" % (item, total_mbs, read_mbs, write_mbs)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "read_throughput": read_val,
                "write_throughput": write_val,
                "read_throughput_mb": read_mbs,
                "write_throughput_mb": write_mbs,
                "throughput_mb": total_mbs
            },
            "details": ""
        }
    }