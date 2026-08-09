def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ps", "-eo", "pid,comm"], mutates=False)
        present = False
        if res.rc == 0:
            for line in res.stdout.splitlines()[1:]:
                f = line.split()
                if len(f) >= 2 and f[1].lower().startswith("vms"):
                    present = True
                    break
        if not present:
            return {"changed": False, "msg": "no vms queue jobs found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered queue jobs",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}]}}

    # check mode
    res = ctx.run(["ps", "-eo", "pid,comm"], mutates=False)
    present = False
    if res.rc == 0:
        for line in res.stdout.splitlines()[1:]:
            f = line.split()
            if len(f) >= 2 and f[1].lower().startswith("vms"):
                present = True
                break
    if not present:
        return {"changed": False, "msg": "no vms queue jobs found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # no real on-host vms_queuejobs data source available
    return {"changed": False, "msg": "vms queue jobs data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}