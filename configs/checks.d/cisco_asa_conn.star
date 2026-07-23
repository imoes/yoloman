def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res_ifname = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.2.1.31.1.1.1.1"
        ], mutates=False)
        ifname_map = {}
        for line in res_ifname.stdout.splitlines():
            if not line:
                continue
            parts = line.strip().split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1].split(": ", 1)
            if len(value) < 2:
                continue
            val = value[1].strip().strip('"')
            idx = oid.rsplit(".", 1)[-1]
            ifname_map[idx] = val
        
        res_ipaddr = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.2.1.4.20.1.1"
        ], mutates=False)
        ipaddr_map = {}
        for line in res_ipaddr.stdout.splitlines():
            if not line:
                continue
            parts = line.strip().split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1].split(": ", 1)
            if len(value) < 2:
                continue
            val = value[1].strip().strip('"')
            idx = oid.rsplit(".", 1)[-1]
            ipaddr_map[idx] = val
        
        res_status = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.2.1.2.2.1.7"
        ], mutates=False)
        admin_status_map = {}
        for line in res_status.stdout.splitlines():
            if not line:
                continue
            parts = line.strip().split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1].split(": ", 1)
            if len(value) < 2:
                continue
            val = value[1].strip()
            idx = oid.rsplit(".", 1)[-1]
            admin_status_map[idx] = val
        
        res_oper = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.2.1.2.2.1.8"
        ], mutates=False)
        oper_status_map = {}
        for line in res_oper.stdout.splitlines():
            if not line:
                continue
            parts = line.strip().split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1].split(": ", 1)
            if len(value) < 2:
                continue
            val = value[1].strip()
            idx = oid.rsplit(".", 1)[-1]
            oper_status_map[idx] = val
        
        discovered = []
        for ip_idx in ipaddr_map:
            admin = admin_status_map.get(ip_idx, "")
            ip_addr = ipaddr_map.get(ip_idx)
            if admin == "1" and ip_addr != None:
                discovered.append({
                    "item": ip_idx,
                    "params": {},
                    "metrics": ["status"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")
    
    res_ifname = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.2.1.31.1.1.1.1"
    ], mutates=False)
    ifname_map = {}
    for line in res_ifname.stdout.splitlines():
        if not line:
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].split(": ", 1)
        if len(value) < 2:
            continue
        val = value[1].strip().strip('"')
        idx = oid.rsplit(".", 1)[-1]
        ifname_map[idx] = val
    
    res_ipaddr = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.2.1.4.20.1.1"
    ], mutates=False)
    ipaddr_map = {}
    for line in res_ipaddr.stdout.splitlines():
        if not line:
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].split(": ", 1)
        if len(value) < 2:
            continue
        val = value[1].strip().strip('"')
        idx = oid.rsplit(".", 1)[-1]
        ipaddr_map[idx] = val
    
    res_admin = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.2.1.2.2.1.7"
    ], mutates=False)
    admin_status_map = {}
    for line in res_admin.stdout.splitlines():
        if not line:
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].split(": ", 1)
        if len(value) < 2:
            continue
        val = value[1].strip()
        idx = oid.rsplit(".", 1)[-1]
        admin_status_map[idx] = val
    
    res_oper = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.2.1.2.2.1.8"
    ], mutates=False)
    oper_status_map = {}
    for line in res_oper.stdout.splitlines():
        if not line:
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].split(": ", 1)
        if len(value) < 2:
            continue
        val = value[1].strip()
        idx = oid.rsplit(".", 1)[-1]
        oper_status_map[idx] = val
    
    if_name = ifname_map.get(item)
    ip_address = ipaddr_map.get(item)
    oper_status = oper_status_map.get(item)
    
    translate_oper_status = {
        "1": ("OK", "up"),
        "2": ("CRIT", "down"),
        "3": ("UNKNOWN", "testing"),
        "4": ("UNKNOWN", "unknown"),
        "5": ("CRIT", "dormant"),
        "6": ("CRIT", "not present"),
        "7": ("CRIT", "lower layer down"),
    }
    
    if ip_address == None:
        return {
            "changed": False,
            "msg": "No such interface",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state = "OK"
    msgs = []
    
    if if_name != None:
        msgs.append("Name: %s" % if_name)
    
    if ip_address != None:
        if if_name != None:
            msgs.append("IP: %s" % ip_address)
        else:
            msgs.append("IP: %s - No network device associated" % ip_address)
            state = "UNKNOWN"
    else:
        msgs.append("IP: Not found!")
        state = "CRIT"
    
    if oper_status != None:
        status_state, status_readable = translate_oper_status.get(
            oper_status, ("UNKNOWN", "N/A")
        )
        msgs.append("Status: %s" % status_readable)
        if status_state == "CRIT":
            state = "CRIT"
        elif status_state == "UNKNOWN" and state != "CRIT":
            state = "UNKNOWN"
    
    metrics = {}
    if oper_status != None and oper_status.isdigit():
        metrics["status"] = int(oper_status)
    elif oper_status != None:
        metrics["status"] = 0
    
    return {
        "changed": False,
        "msg": "; ".join(msgs),
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
