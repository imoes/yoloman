def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/sansymphony_ports"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "cannot read sansymphony_ports data",
                    "data": {"discovery": []}}
        
        discovery_items = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                portname, porttype, portstatus = parts[0], parts[1], parts[2]
                if portstatus == "True":
                    discovery_items.append({
                        "item": portname,
                        "params": {},
                        "metrics": []
                    })
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode for specific item
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/sansymphony_ports"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "cannot read sansymphony_ports data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            portname, porttype, portstatus = parts[0], parts[1], parts[2]
            if portname == item:
                if portstatus == "True":
                    return {
                        "changed": False,
                        "msg": "%s Port %s is up" % (porttype, portname),
                        "data": {
                            "state": "OK",
                            "metrics": {},
                            "details": ""
                        }
                    }
                else:
                    return {
                        "changed": False,
                        "msg": "%s Port %s is down" % (porttype, portname),
                        "data": {
                            "state": "CRIT",
                            "metrics": {},
                            "details": ""
                        }
                    }
    
    # Item not found
    return {
        "changed": False,
        "msg": "port %s not found" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }