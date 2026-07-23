def main(ctx, params):
    # Discovery mode: _discover is true
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/cmk-agent/agent-citrix_hostsystem"], mutates=False)
        vms = []
        pool = ""
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) >= 2:
                    key = parts[0]
                    value = parts[1]
                    if key == "VMName":
                        if value not in vms:
                            vms.append(value)
                    elif key == "CitrixPoolName":
                        if pool == "":
                            pool = value
        # Single-service check: one entry with empty item
        discovery = []
        if vms:
            discovery.append({"item": "", "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d VMs" % len(vms) if vms else "no VMs found",
                "data": {"discovery": discovery}}
    
    # Check mode: normal path
    # Read agent section data
    res = ctx.run(["cat", "/var/lib/cmk-agent/agent-citrix_hostsystem"], mutates=False)
    vms = []
    pool = ""
    if res.rc == 0:
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) >= 2:
                key = parts[0]
                value = parts[1]
                if key == "VMName":
                    if value not in vms:
                        vms.append(value)
                elif key == "CitrixPoolName":
                    if pool == "":
                        pool = value
    
    # Build summary
    if not vms:
        return {"changed": False, "msg": "no VMs running",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    summary = "%d VMs running: %s" % (len(vms), ", ".join(vms))
    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": {"vm_count": len(vms)}, "details": ""}}