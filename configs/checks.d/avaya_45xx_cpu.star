# Module-level constants for SNMP OIDs and defaults
AVAYA_45XX_CPU_OID_BASE = ".1.3.6.1.4.1.45.1.6.3.8.1.1.5.3"
AVAYA_SYS_OID = ".1.3.6.1.2.1.1.2.0"
AVAYA_ENTERPRISE_OID = ".1.3.6.1.4.1.45"
AVAYA_45XX_CPU_DEFAULT_WARN = 90.0
AVAYA_45XX_CPU_DEFAULT_CRIT = 95.0

def _detect_avaya_device(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, AVAYA_SYS_OID], mutates=False)
    if res.rc != 0:
        return False
    output = res.stdout.strip()
    return output.find(AVAYA_ENTERPRISE_OID) >= 0

def _get_cpu_utilization(ctx, host, community):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, AVAYA_45XX_CPU_OID_BASE], mutates=False)
    if res.rc != 0:
        return []
    
    utilizations = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        value_str = parts[-1]
        if value_str.isdigit():
            utilizations.append(int(value_str))
    
    return utilizations

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        if not _detect_avaya_device(ctx, host, community):
            return {"changed": False, "msg": "not an Avaya device", "data": {"discovery": []}}
        
        utilizations = _get_cpu_utilization(ctx, host, community)
        discovery_items = []
        for idx, _util in enumerate(utilizations):
            item = str(idx)
            discovery_items.append({
                "item": item,
                "params": {"levels": (AVAYA_45XX_CPU_DEFAULT_WARN, AVAYA_45XX_CPU_DEFAULT_CRIT)},
                "metrics": ["cpu_util"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d CPUs" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    
    if not _detect_avaya_device(ctx, host, community):
        return {
            "changed": False,
            "msg": "not an Avaya device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    utilizations = _get_cpu_utilization(ctx, host, community)
    
    # Find the requested CPU item
    if int(item) >= len(utilizations):
        return {
            "changed": False,
            "msg": "CPU item %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    util = utilizations[int(item)]
    levels = params.get("levels", (AVAYA_45XX_CPU_DEFAULT_WARN, AVAYA_45XX_CPU_DEFAULT_CRIT))
    warn = levels[0] if levels else AVAYA_45XX_CPU_DEFAULT_WARN
    crit = levels[1] if levels else AVAYA_45XX_CPU_DEFAULT_CRIT
    
    # Determine state
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "CPU %s: %d%%" % (item, util),
        "data": {
            "state": state,
            "metrics": {"cpu_util": util},
            "details": ""
        }
    }
