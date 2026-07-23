# Module-level constants
METRICS_MAP = {
    "used_percent": "used_percent",
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the quota SNMP section
        base_oid = ".1.3.6.1.4.1.12124.1.12.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid + ".5"  # quotaPath
        ], mutates=False)
        
        items = []
        if res.rc == 0 and res.stdout:
            # Extract paths by parsing snmpwalk output lines: "<OID> = STRING: <path>"
            paths = []
            for line in res.stdout.splitlines():
                if ": STRING: " in line:
                    parts = line.split(": STRING: ", 1)
                    if len(parts) == 2:
                        path = parts[1].strip().strip('"')
                        if path:
                            paths.append(path)
            
            # For each path, get thresholds via snmpget (single values)
            for path in paths:
                # Hard threshold (OID .7), soft threshold defined (.8), soft threshold (.9)
                # Advisory threshold defined (.10), advisory threshold (.11), usage (.13)
                # We only need path and thresholds to build item, defaults are computed later
                item = path
                items.append({
                    "item": item,
                    "params": {},
                    "metrics": ["used_percent"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d quotas" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: examine one quota item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Build a list of all quota info (paths + thresholds) for filtering
    base_oid = ".1.3.6.1.4.1.12124.1.12.1.1"
    # 1. Get all paths (like discovery)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base_oid + ".5"
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse paths
    paths = {}
    for line in res.stdout.splitlines():
        if ": STRING: " in line:
            parts = line.split(": STRING: ", 1)
            if len(parts) == 2:
                path = parts[1].strip().strip('"')
                if path:
                    paths[path] = True
    
    if item not in paths:
        return {
            "changed": False,
            "msg": "quota not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch thresholds for this specific path using snmpget
    # We need to map item path to its index in the table.
    # Get OID to path mapping with snmpwalk, then derive OIDs for thresholds
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base_oid + ".5"
    ], mutates=False)
    
    # Map index -> path
    index_to_path = {}
    for line in res.stdout.splitlines():
        if ": STRING: " in line:
            parts = line.split(": STRING: ", 1)
            if len(parts) == 2:
                path = parts[1].strip().strip('"')
                # Extract OID index: ".1.3.6.1.4.1.12124.1.12.1.1.5.<index>"
                oid_base = parts[0].strip()
                # Extract last part after last dot as index
                idx_parts = oid_base.split(".")
                if len(idx_parts) >= 1:
                    idx = idx_parts[-1]
                    index_to_path[idx] = path
    
    # Find index for our item
    target_idx = None
    for idx, path in index_to_path.items():
        if path == item:
            target_idx = idx
            break
    
    if target_idx == None:
        return {
            "changed": False,
            "msg": "quota index not found for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch thresholds for this index: .5 (path), .7 (hard), .8 (soft defined), .9 (soft), .10 (adv defined), .11 (adv), .13 (usage)
    # Use snmpget for scalar OIDs
    oids = [
        base_oid + ".7." + target_idx,  # hard_threshold
        base_oid + ".8." + target_idx,  # soft_threshold_defined
        base_oid + ".9." + target_idx,  # soft_threshold
        base_oid + ".10." + target_idx, # advisory_threshold_defined
        base_oid + ".11." + target_idx, # advisory_threshold
        base_oid + ".13." + target_idx, # usage
    ]
    
    # Build one snmpget command for all OIDs
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
    ] + oids, mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP get failed for quota thresholds",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: "<OID> = <type>: <value>"
    values = {}
    for line in res.stdout.splitlines():
        if " = " in line:
            parts = line.split(" = ", 1)
            if len(parts) == 2:
                oid = parts[0].strip()
                val_part = parts[1].strip()
                # Extract value: TYPE: value
                if ": " in val_part:
                    v = val_part.split(": ", 1)[1].strip()
                    # Remove trailing quotes if any
                    if v.startswith('"') and v.endswith('"'):
                        v = v[1:-1]
                    # Map to short names
                    last = oid.split(".")[-1]
                    if last == "7":
                        values["hard"] = v
                    elif last == "8":
                        values["soft_def"] = v
                    elif last == "9":
                        values["soft"] = v
                    elif last == "10":
                        values["adv_def"] = v
                    elif last == "11":
                        values["adv"] = v
                    elif last == "13":
                        values["usage"] = v
    
    # Validate required fields
    required = ["hard", "soft_def", "soft", "adv_def", "adv", "usage"]
    for r in required:
        if r not in values:
            return {
                "changed": False,
                "msg": "missing quota field: " + r,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    
    # Compute assumed_size = hard or soft or adv threshold (non-zero)
    hard = int(values["hard"]) if values["hard"].isdigit() else 0
    soft = int(values["soft"]) if values["soft"].isdigit() else 0
    adv = int(values["adv"]) if values["adv"].isdigit() else 0
    
    assumed_size = hard or soft or adv
    usage = int(values["usage"]) if values["usage"].isdigit() else 0
    
    if assumed_size == 0:
        return {
            "changed": False,
            "msg": "no threshold defined for quota " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Compute percentages
    used_percent = float(usage * 100) / float(assumed_size) if assumed_size != 0 else 0.0
    
    # Determine levels: if no levels in params, derive from thresholds if defined
    warn = params.get("warn")
    crit = params.get("crit")
    if warn == None or crit == None:
        # Use Checkmk defaults
        soft_def = values["soft_def"]
        adv_def = values["adv_def"]
        
        if adv_def == "1":
            warn_pct = float(adv) * 100.0 / float(assumed_size) if assumed_size != 0 else 80.0
        else:
            warn_pct = 80.0
        
        if soft_def == "1":
            crit_pct = float(soft) * 100.0 / float(assumed_size) if assumed_size != 0 else 90.0
        else:
            crit_pct = 90.0
        
        warn = warn_pct
        crit = crit_pct
    
    # Determine state
    state = "OK"
    if crit != None and used_percent >= float(crit):
        state = "CRIT"
    elif warn != None and used_percent >= float(warn):
        state = "WARN"
    
    # Build message
    msg = "%s %f%% used" % (item, used_percent)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": ""
        },
    }
