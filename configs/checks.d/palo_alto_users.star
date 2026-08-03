def _levels(params):
    levels = params.get("levels", "ignore")
    if levels == "ignore":
        return None, None
    kind = levels[0]
    thr = levels[1]
    if kind == "abs_user":
        return thr, None
    if kind == "perc_user":
        return None, thr
    return None, None

def _grade_upper(value, levels):
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0 or "25461" not in sys_oid.stdout:
            return {"changed": False, "msg": "Palo Alto device not found", "data": {"discovery": []}}
        max_users_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.25461.2.1.2.5.1.2.0"], mutates=False)
        num_users_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.25461.2.1.2.5.1.3.0"], mutates=False)
        if max_users_res.rc != 0 or num_users_res.rc != 0:
            return {"changed": False, "msg": "Palo Alto users OID not available", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"levels": "ignore"}, "metrics": ["num_user", "max_user"]}]}}

    item = params.get("item", "")
    max_users_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.25461.2.1.2.5.1.2.0"], mutates=False)
    num_users_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.25461.2.1.2.5.1.3.0"], mutates=False)
    if max_users_res.rc != 0 or num_users_res.rc != 0:
        return {"changed": False, "msg": "no Palo Alto users data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    max_users = int(max_users_res.stdout.strip())
    num_users = int(num_users_res.stdout.strip())
    user_perc = num_users / max_users * 100 if max_users > 0 else 0
    abs_levels, perc_levels = _levels(params)
    state_abs = _grade_upper(num_users, abs_levels)
    state_perc = _grade_upper(user_perc, perc_levels)
    if state_abs == "CRIT" or state_perc == "CRIT":
        state = "CRIT"
    elif state_abs == "WARN" or state_perc == "WARN":
        state = "WARN"
    else:
        state = "OK"
    msg = "Number of logged in users: %f%% - %d of %d" % (user_perc, num_users, max_users)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"num_user": num_users, "max_user": max_users}, "details": ""}}