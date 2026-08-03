def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["systemctl", "is-active", "zerto-agent"], mutates=False)
        installed = res.rc == 0 or res.rc == 3
        if not installed:
            res2 = ctx.run(["systemctl", "list-unit-files"], mutates=False)
            if res2.rc != 0:
                return {"changed": False, "msg": "no zerto agent found",
                        "discovery": []}
            has_zerto = False
            for line in res2.stdout.splitlines():
                if "zerto" in line.lower():
                    has_zerto = True
                    break
            if not has_zerto:
                return {"changed": False, "msg": "no zerto agent found",
                        "discovery": []}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}
    res = ctx.run(["systemctl", "is-active", "zerto-agent"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "zerto agent not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    active = res.stdout.strip() == "active"
    if not active:
        out = ctx.run(["systemctl", "status", "zerto-agent"], mutates=False)
        details = out.stdout + "\n" + out.stderr
        return {"changed": False, "msg": "Error starting agent",
                "data": {"state": "CRIT", "metrics": {}, "details": details}}
    return {"changed": False, "msg": "Agent started without problem",
            "data": {"state": "OK", "metrics": {}, "details": ""}}