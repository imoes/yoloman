def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mongosh", "--version"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "no mongosh found", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "mongosh not available", "data": {"discovery": []}}
        res2 = ctx.run(["mongosh", "--quiet", "--eval", "JSON.stringify(db.adminCommand({hello:true}))"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "cannot reach MongoDB", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []}
            ]},
        }

    res = ctx.run(["mongosh", "--quiet", "--eval", "JSON.stringify(db.adminCommand({balancerState:1}))"], mutates=False)
    if res.rc == 127:
        return {
            "changed": False,
            "msg": "mongosh not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "No mongosh binary found on host"},
        }
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "cannot determine balancer state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "mongosh failed: %s" % res.stderr},
        }
    data = None
    if res.stdout:
        data = json.decode(res.stdout)
    if data == None:
        return {
            "changed": False,
            "msg": "no balancer state data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Empty balancer state response from MongoDB"},
        }
    balancer_enabled = data.get("balancerEnabled", False)
    if balancer_enabled:
        return {
            "changed": False,
            "msg": "Balancer: enabled",
            "data": {"state": "OK", "metrics": {}, "details": "MongoDB balancer is enabled and active"},
        }
    return {
        "changed": False,
        "msg": "Balancer: disabled",
        "data": {"state": "CRIT", "metrics": {}, "details": "MongoDB balancer is disabled"},
    }