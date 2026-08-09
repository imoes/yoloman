def _discover(ctx, params):
    res = ctx.run(["MobileIron", "--version"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "Mobileiron not installed",
                "data": {"discovery": []}}
    if res.rc != 0:
        return {"changed": False, "msg": "Mobileiron not reachable",
                "data": {"discovery": []}}
    info = ctx.run(["/usr/local/mobileiron/bin/device_info", "--json"], mutates=False)
    if info.rc != 0 or not info.stdout:
        return {"changed": False, "msg": "No Mobileiron data found",
                "data": {"discovery": [
                    {"item": "", "params": {"policy_violation_levels": [2, 3], "ignore_compliance": False},
                     "metrics": ["mobileiron_policyviolationcount"]}]}}
    data = json.decode(info.stdout)
    if not data.get("registered"):
        return {"changed": False, "msg": "Mobileiron not registered",
                "data": {"discovery": []}}
    return {"changed": False, "msg": "discovered Mobileiron compliance",
            "data": {"discovery": [
                {"item": "", "params": {"policy_violation_levels": [2, 3], "ignore_compliance": False},
                 "metrics": ["mobileiron_policyviolationcount"]}]}}


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)

    info = ctx.run(["/usr/local/mobileiron/bin/device_info", "--json"], mutates=False)
    if info.rc != 0 or not info.stdout:
        return {"changed": False, "msg": "Mobileiron device info not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(info.stdout)
    if not data.get("registered"):
        return {"changed": False, "msg": "Mobileiron not registered",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    count = data.get("policy_violation_count")
    if count == None:
        count = 0
    compliance_state = data.get("compliance_state", False)
    levels = params.get("policy_violation_levels", [2, 3])
    warn = levels[0] if len(levels) > 0 else 2
    crit = levels[1] if len(levels) > 1 else 3
    ignore_compliance = params.get("ignore_compliance", False)

    state = "CRIT" if count >= crit else ("WARN" if count >= warn else "OK")

    metrics = {"mobileiron_policyviolationcount": count}

    if not ignore_compliance:
        if not compliance_state:
            state = "CRIT"
    summary = "Policy violation count: %d, Compliant: %s" % (count, compliance_state)
    if ignore_compliance:
        summary = summary + " (ignored)"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}