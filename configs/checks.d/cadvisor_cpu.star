def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "http://localhost:8080/api/v1.3/stats"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if not res.stdout.startswith("{"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout.startswith("{") else {}
        if type(data) != "dict":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        cpu = data.get("cpu")
        if type(cpu) != "dict":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if not cpu.get("user") or not cpu.get("system"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["user", "system", "util"]}]}}

    res = ctx.run(["curl", "-s", "http://localhost:8080/api/v1.3/stats"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout.startswith("{"):
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout) if res.stdout.startswith("{") else {}
    if type(data) != "dict":
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cpu = data.get("cpu")
    if type(cpu) != "dict":
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not cpu.get("user") or not cpu.get("system"):
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    user_val = cpu["user"]
    system_val = cpu["system"]
    cpu_user = float(user_val) if type(user_val) == "string" or type(user_val) == "int" or type(user_val) == "float" else -1.0
    cpu_system = float(system_val) if type(system_val) == "string" or type(system_val) == "int" or type(system_val) == "float" else -1.0
    if cpu_user < 0.0 or cpu_system < 0.0:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_total = cpu_user + cpu_system

    util_levels = params.get("util")
    if util_levels != None:
        warn = float(util_levels[0]) if util_levels[0] != None else 80.0
        crit = float(util_levels[1]) if util_levels[1] != None else 90.0
        state = "CRIT" if cpu_total >= crit else ("WARN" if cpu_total >= warn else "OK")
    else:
        state = "OK"

    summary = "User: %f%%, System: %f%%, Total CPU: %f%%" % (cpu_user, cpu_system, cpu_total)
    return {"changed": False, "msg": summary,
            "data": {"state": state,
                     "metrics": {"user": cpu_user, "system": cpu_system, "util": cpu_total},
                     "details": ""}}