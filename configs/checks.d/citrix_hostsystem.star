def main(ctx, params):
    if params.get("_discover"):
        out = []
        res = ctx.run(["xe", "host-list", "params=name-label", "--minimal"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 Citrix items", "data": {"discovery": []}}
        # Parse the minimal CSV output
        names = []
        for token in res.stdout.strip().split("\n"):
            token = token.strip()
            if token:
                names.append(token)

        if not names:
            return {"changed": False, "msg": "discovered 0 Citrix items", "data": {"discovery": []}}

        # Discover VMs
        vm_res = ctx.run(["xe", "vm-list", "--minimal"], mutates=False)
        vms = []
        if vm_res.rc == 0 and vm_res.stdout.strip():
            for token in vm_res.stdout.strip().split("\n"):
                token = token.strip()
                if token:
                    vms.append(token)

        if vms:
            out.append({"item": "", "params": {}, "metrics": [], "service_labels": {"type": "vms"}})

        # Discover Host Info (pool name)
        pool_res = ctx.run(["xe", "pool-list", "params=name-label", "--minimal"], mutates=False)
        pool = ""
        if pool_res.rc == 0 and pool_res.stdout.strip():
            first = pool_res.stdout.strip().split("\n")
            if first and first[0].strip():
                pool = first[0].strip()

        if pool:
            out.append({"item": "", "params": {}, "metrics": [], "service_labels": {"type": "hostinfo"}})

        return {"changed": False, "msg": "discovered %d Citrix items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    stype = params.get("_type", "")
    if stype == "vms":
        res = ctx.run(["xe", "vm-list", "--minimal"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "xe vm-list failed: %s" % res.stderr.strip(), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        vms = []
        for token in res.stdout.strip().split("\n"):
            token = token.strip()
            if token:
                vms.append(token)
        return {"changed": False, "msg": "%d VMs running: %s" % (len(vms), ", ".join(vms)), "data": {"state": "OK", "metrics": {}, "details": ""}}

    # Host Info
    pool_res = ctx.run(["xe", "pool-list", "params=name-label", "--minimal"], mutates=False)
    if pool_res.rc != 0:
        return {"changed": False, "msg": "xe pool-list failed: %s" % pool_res.stderr.strip(), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pool = ""
    if pool_res.stdout.strip():
        first = pool_res.stdout.strip().split("\n")
        if first and first[0].strip():
            pool = first[0].strip()
    return {"changed": False, "msg": "Citrix Pool Name: %s" % pool, "data": {"state": "OK", "metrics": {}, "details": ""}}