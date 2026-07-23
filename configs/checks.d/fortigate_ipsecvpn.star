# Module-level constants
OID_BASE = ".1.3.6.1.4.1.12356.101.12.2.2.1"
OID_TUNNEL_NAME = OID_BASE + ".3"
OID_TUNNEL_STATUS = OID_BASE + ".20"

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode: gather all tunnels and yield one service
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, OID_BASE
        ], mutates=False)
        
        tunnels = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ", 2)
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value_part = parts[1].strip()
            
            if oid_full.startswith(OID_TUNNEL_NAME):
                suffix = oid_full[len(OID_TUNNEL_NAME):]
                if suffix.startswith("."):
                    index = suffix[1:]
                    name = value_part.strip('"')
                    tunnels[index] = {"name": name}
            elif oid_full.startswith(OID_TUNNEL_STATUS):
                suffix = oid_full[len(OID_TUNNEL_STATUS):]
                if suffix.startswith("."):
                    index = suffix[1:]
                    if index in tunnels:
                        tunnels[index]["status"] = value_part
        
        # Single service for all tunnels (per original Service() discovery)
        discovery = []
        if tunnels:
            discovery.append({
                "item": "",
                "params": {"tunnels_ignore_levels": [], "levels": (1, 2)},
                "metrics": ["active_vpn_tunnels"]
            })
        
        return {"changed": False, "msg": "discovered %d tunnels" % len(tunnels),
                "data": {"discovery": discovery}}
    
    # Check mode: verify all tunnels (single-service check)
    item = params.get("item", "")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, OID_BASE
    ], mutates=False)
    
    tunnels = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ", 2)
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        
        if oid_full.startswith(OID_TUNNEL_NAME):
            suffix = oid_full[len(OID_TUNNEL_NAME):]
            if suffix.startswith("."):
                index = suffix[1:]
                name = value_part.strip('"')
                tunnels[index] = {"name": name}
        elif oid_full.startswith(OID_TUNNEL_STATUS):
            suffix = oid_full[len(OID_TUNNEL_STATUS):]
            if suffix.startswith("."):
                index = suffix[1:]
                if index in tunnels:
                    tunnels[index]["status"] = value_part
    
    # Extract parameters with defaults
    levels = params.get("levels", [1, 2])
    warn = levels[0] if len(levels) > 0 else 1
    crit = levels[1] if len(levels) > 1 else 2
    tunnels_ignore = params.get("tunnels_ignore_levels", [])
    
    num_down = 0
    num_ignored = 0
    tunnels_down_names = []
    
    for index, data in tunnels.items():
        status = data.get("status")
        name = data.get("name", "")
        if status == "1":
            num_down += 1
            tunnels_down_names.append(name)
            if name in tunnels_ignore:
                num_ignored += 1
    
    num_total = len(tunnels)
    num_up = num_total - num_down
    num_down_and_not_ignored = num_down - num_ignored
    
    infotext = "Total: %d, Up: %d, Down: %d, Ignored: %d" % (num_total, num_up, num_down, num_ignored)
    
    state = "OK"
    if crit != None and num_down_and_not_ignored >= crit:
        state = "CRIT"
    elif warn != None and num_down_and_not_ignored >= warn:
        state = "WARN"
    if state != "OK" and (warn != None or crit != None):
        infotext = infotext + " (warn/crit at " + str(warn) + "/" + str(crit) + ")"
    
    long_output = []
    
    # Down and not ignored
    down_not_ignored = []
    for name in tunnels_down_names:
        if name not in tunnels_ignore:
            down_not_ignored.append(name)
    if down_not_ignored:
        long_output.append("Down and not ignored:")
        sorted_names = sorted(down_not_ignored)
        long_output.append(", ".join(sorted_names))
    
    if tunnels_down_names:
        long_output.append("Down:")
        sorted_names = sorted(tunnels_down_names)
        long_output.append(", ".join(sorted_names))
    
    ignored_names = []
    for name in tunnels_ignore:
        if name in tunnels_down_names:
            ignored_names.append(name)
    if ignored_names:
        long_output.append("Ignored:")
        sorted_names = sorted(ignored_names)
        long_output.append(", ".join(sorted_names))
    
    details = ""
    if long_output:
        details = long_output[0]
        for i in range(1, len(long_output)):
            details = details + "\n" + long_output[i]
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {"active_vpn_tunnels": num_up},
            "details": details
        }
    }
