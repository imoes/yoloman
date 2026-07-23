def main(ctx, params):
    if params.get("_discover"):
        # Discovery: simulate parsing HACMP subsystem data
        # We use ps to detect HACMP/CAA/RSCT processes since the agent section isn't available
        
        # CAA subsystems
        caa_subsys = []
        res = ctx.run(["ps", "-ef"], mutates=False)
        lines = res.stdout.splitlines()
        for line in lines:
            if "clcomd" in line or "clconfd" in line:
                parts = line.split()
                if len(parts) >= 2:
                    pid = parts[1]
                    subsys_name = "clcomd" if "clcomd" in line else "clconfd"
                    status = "active" if pid.isdigit() else "inoperative"
                    caa_subsys.append([subsys_name, status])
        
        # PowerHA SystemMirror subsystems
        powerha_subsys = []
        for subsys in ["clstrmgrES", "clevmgrdES"]:
            res = ctx.run(["ps", "-ef"], mutates=False)
            found = False
            for line in res.stdout.splitlines():
                if subsys in line:
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        powerha_subsys.append([subsys, "active"])
                        found = True
                        break
            if not found:
                powerha_subsys.append([subsys, "inoperative"])
        
        # RSCT subsystems
        rsct_subsys = []
        for subsys in ["cthags", "ctrmc"]:
            res = ctx.run(["ps", "-ef"], mutates=False)
            found = False
            for line in res.stdout.splitlines():
                if subsys in line:
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        rsct_subsys.append([subsys, "active"])
                        found = True
                        break
            if not found:
                rsct_subsys.append([subsys, "inoperative"])
        
        # Build parsed structure
        parsed = {}
        if len(caa_subsys) > 0:
            parsed["CAA"] = caa_subsys
        if len(powerha_subsys) > 0:
            parsed["PowerHA SystemMirror"] = powerha_subsys
        if len(rsct_subsys) > 0:
            parsed["RSCT"] = rsct_subsys
        
        # Discovery yields one Service per subsystem group
        discovery_items = []
        for item in parsed:
            # Extract metric names (subsystem names) for this group
            metrics = []
            for entry in parsed[item]:
                if len(entry) > 0:
                    metrics.append(entry[0])
            
            discovery_items.append({
                "item": item,
                "params": {},
                "metrics": metrics
            })
        
        return {"changed": False, "msg": "discovered %d HACMP subsystem groups" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    # Check mode: check a specific item (subsystem group)
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Re-parse the same way as discovery to get the data for this item
    hacmp_section = {}
    
    # CAA subsystems
    caa_subsys = []
    res = ctx.run(["ps", "-ef"], mutates=False)
    lines = res.stdout.splitlines()
    for line in lines:
        if "clcomd" in line or "clconfd" in line:
            parts = line.split()
            if len(parts) >= 2:
                pid = parts[1]
                subsys_name = "clcomd" if "clcomd" in line else "clconfd"
                status = "active" if pid.isdigit() else "inoperative"
                caa_subsys.append([subsys_name, status])
    if len(caa_subsys) > 0:
        hacmp_section["CAA"] = caa_subsys
    
    # PowerHA SystemMirror subsystems
    powerha_subsys = []
    for subsys in ["clstrmgrES", "clevmgrdES"]:
        res = ctx.run(["ps", "-ef"], mutates=False)
        found = False
        for line in res.stdout.splitlines():
            if subsys in line:
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    powerha_subsys.append([subsys, "active"])
                    found = True
                    break
        if not found:
            powerha_subsys.append([subsys, "inoperative"])
    if len(powerha_subsys) > 0:
        hacmp_section["PowerHA SystemMirror"] = powerha_subsys
    
    # RSCT subsystems
    rsct_subsys = []
    for subsys in ["cthags", "ctrmc"]:
        res = ctx.run(["ps", "-ef"], mutates=False)
        found = False
        for line in res.stdout.splitlines():
            if subsys in line:
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    rsct_subsys.append([subsys, "active"])
                    found = True
                    break
        if not found:
            rsct_subsys.append([subsys, "inoperative"])
    if len(rsct_subsys) > 0:
        hacmp_section["RSCT"] = rsct_subsys
    
    # Get data for the requested item
    data = hacmp_section.get(item)
    if data == None or len(data) == 0:
        return {"changed": False, "msg": "no such subsystem group: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine overall state - if any subsystem is inoperative, report CRIT
    all_active = True
    for entry in data:
        if len(entry) >= 2 and entry[1] != "active":
            all_active = False
            break
    
    state = "OK" if all_active else "CRIT"
    
    # Build summary message listing all subsystems and their statuses
    summaries = []
    for entry in data:
        if len(entry) >= 2:
            summaries.append("Subsystem: %s, Status: %s" % (entry[0], entry[1]))
    
    return {"changed": False, "msg": ", ".join(summaries),
            "data": {"state": state, "metrics": {}, "details": ""}}