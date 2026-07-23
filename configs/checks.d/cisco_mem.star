# cisco_mem Starlark check module - read-only, SNMP-based
# Translates cmk.plugins.cisco.lib_mem.check_cisco_mem_sub and discovery_cisco_mem

# Default parameters from Checkmk
DEFAULT_LEVELS = (80.0, 90.0)
DEFAULT_TREND_RANGE = 24
DEFAULT_TREND_TIMELEFT = (12, 6)

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the enhanced 32-bit and legacy SNMP trees
        # Prefer enhanced 32-bit if available (cempMemPoolName), fallback to legacy (ciscoMemoryPoolName)
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # First try enhanced 32-bit (cempMemPoolName .1.3.6.1.4.1.9.9.221.1.1.1.1.3)
        res_enhanced = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.9.9.221.1.1.1.1.3"
        ], mutates=False)
        
        # Extract pool names from enhanced tree
        enhanced_pools = []
        for line in res_enhanced.stdout.splitlines():
            if "=" in line:
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    name = parts[1].strip()
                    # Extract the index from OID path: ...1.3.6.1.4.1.9.9.221.1.1.1.1.3.<index>
                    oid = parts[0].strip()
                    index = oid.rsplit(".", 1)[-1] if "." in oid else ""
                    if name and index:
                        enhanced_pools.append({"name": name.strip('"'), "index": index})
        
        if enhanced_pools:
            # Get used and free values for enhanced pools
            # cempMemPoolUsed: .1.3.6.1.4.1.9.9.221.1.1.1.1.7.<index>
            # cempMemPoolFree: .1.3.6.1.4.1.9.9.221.1.1.1.1.8.<index>
            used_oids = ".".join([".1.3.6.1.4.1.9.9.221.1.1.1.1.7"] + [p["index"] for p in enhanced_pools])
            free_oids = ".".join([".1.3.6.1.4.1.9.9.221.1.1.1.1.8"] + [p["index"] for p in enhanced_pools])
            
            # Use individual snmpget calls for each OID to avoid parsing complexity
            results = []
            for pool in enhanced_pools:
                idx = pool["index"]
                used_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, 
                                   ".1.3.6.1.4.1.9.9.221.1.1.1.1.7." + idx], mutates=False)
                free_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, 
                                   ".1.3.6.1.4.1.9.9.221.1.1.1.1.8." + idx], mutates=False)
                
                used = _extract_snmp_value(used_res.stdout)
                free = _extract_snmp_value(free_res.stdout)
                
                if used != None and free != None:
                    results.append({
                        "item": pool["name"],
                        "params": {"levels": DEFAULT_LEVELS},
                        "metrics": ["mem_used_percent", "mem_used"]
                    })
            
            return {
                "changed": False,
                "msg": "discovered %d memory pools" % len(results),
                "data": {"discovery": results}
            }
        
        # Fallback to legacy tree: ciscoMemoryPoolName .1.3.6.1.4.1.9.9.48.1.1.1.2
        res_legacy = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.9.9.48.1.1.1.2"
        ], mutates=False)
        
        legacy_pools = []
        for line in res_legacy.stdout.splitlines():
            if "=" in line:
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    name = parts[1].strip()
                    oid = parts[0].strip()
                    index = oid.rsplit(".", 1)[-1] if "." in oid else ""
                    if name and index:
                        legacy_pools.append({"name": name.strip('"'), "index": index})
        
        results = []
        for pool in legacy_pools:
            idx = pool["index"]
            used_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, 
                               ".1.3.6.1.4.1.9.9.48.1.1.1.5." + idx], mutates=False)
            free_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, 
                               ".1.3.6.1.4.1.9.9.48.1.1.1.6." + idx], mutates=False)
            
            used = _extract_snmp_value(used_res.stdout)
            free = _extract_snmp_value(free_res.stdout)
            
            if used != None and free != None:
                results.append({
                    "item": pool["name"],
                    "params": {"levels": DEFAULT_LEVELS},
                    "metrics": ["mem_used_percent", "mem_used"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d memory pools" % len(results),
            "data": {"discovery": results}
        }
    
    # Check mode: verify one item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Try enhanced 32-bit first (prefer snmpget with index)
    # Get the index for this item from discovery if possible, otherwise query all
    # For simplicity, query the legacy tree which is more predictable
    
    # Query legacy tree: get all pool names
    res_names = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.9.9.48.1.1.1.2"
    ], mutates=False)
    
    pool_index = ""
    for line in res_names.stdout.splitlines():
        if "=" in line:
            parts = line.strip().split(" = ")
            if len(parts) == 2 and parts[1].strip().strip('"') == item:
                oid = parts[0].strip()
                pool_index = oid.rsplit(".", 1)[-1]
                break
    
    if not pool_index:
        return {
            "changed": False,
            "msg": "memory pool not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get used and free values
    used_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, 
                       ".1.3.6.1.4.1.9.9.48.1.1.1.5." + pool_index], mutates=False)
    free_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, 
                       ".1.3.6.1.4.1.9.9.48.1.1.1.6." + pool_index], mutates=False)
    
    used = _extract_snmp_value(used_res.stdout)
    free = _extract_snmp_value(free_res.stdout)
    
    if used == None or free == None:
        return {
            "changed": False,
            "msg": "cannot retrieve memory data for pool: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Calculate totals and usage
    total = free + used
    if total == 0:
        return {
            "changed": False,
            "msg": "Cannot calculate memory usage: Device reports total memory 0",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    usage_pct = (used * 100.0) / total
    warn, crit = params.get("levels", DEFAULT_LEVELS)
    
    # Determine state based on usage percentage
    state = "OK"
    if usage_pct >= crit:
        state = "CRIT"
    elif usage_pct >= warn:
        state = "WARN"
    
    # Format message
    mib = "MiB"
    used_mb = used / (1024 * 1024)
    total_mb = total / (1024 * 1024)
    msg = "Usage: %f%% - %d %s of %d %s" % (usage_pct, int(used_mb), mib, int(total_mb), mib)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "mem_used_percent": usage_pct,
                "mem_used": used,
                "mem_total": total
            },
            "details": ""
        },
    }

def _extract_snmp_value(output):
    # Parse snmpget/snmpwalk output: OID = INTEGER: value or STRING: "value"
    lines = output.strip().split("\n")
    if not lines:
        return None
    line = lines[0].strip()
    if "=" in line:
        parts = line.split(" = ")
        if len(parts) >= 2:
            value_part = parts[1].strip()
            if value_part.startswith("INTEGER:"):
                return int(value_part.split(":", 1)[1].strip())
            elif value_part.startswith("Counter32:"):
                return int(value_part.split(":", 1)[1].strip())
            elif value_part.startswith("Counter64:"):
                return int(value_part.split(":", 1)[1].strip())
            elif value_part.isdigit():
                return int(value_part)
    return None
