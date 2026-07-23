def main(ctx, params):
    # Discovery mode: checkmk.decru_cpu yields one service per host if section exists
    if params.get("_discover"):
        # Detect decru by checking if host has "datafort" in uname output
        uname_res = ctx.run(["uname", "-a"], mutates=False)
        if uname_res.rc != 0 or "datafort" not in uname_res.stdout.lower():
            return {"changed": False, "msg": "discovered 0 services", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 service", "data": {"discovery": [{"item": "", "params": {}, "metrics": ["user", "system", "interrupt"]}]}}

    # Check mode: process single item (always "" for this check)
    # Fetch decru_cpu section data
    res = ctx.run(["agentctl", "get", "decru_cpu"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "agent data for decru_cpu not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Guard before json.decode: validate output is non-empty
    if not res.stdout:
        return {"changed": False, "msg": "agent data for decru_cpu not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse JSON output
    section = json.decode(res.stdout)

    # Validate section structure
    if type(section) != "list" or len(section) != 5:
        return {"changed": False, "msg": "invalid decru_cpu section: expected 5 rows, got %d" % len(section), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Convert values to floats
    values = []
    for row in section:
        if type(row) != "list" or len(row) != 1:
            return {"changed": False, "msg": "invalid row in decru_cpu", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        v = row[0]
        # Guard against non-numeric values
        if type(v) == "string":
            if not v.replace(".", "").replace("-", "").isdigit():
                return {"changed": False, "msg": "decru_cpu values are not numbers", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            values.append(float(v))
        elif type(v) == "float" or type(v) == "int":
            values.append(float(v))
        else:
            return {"changed": False, "msg": "decru_cpu values are not numbers", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    user, nice, system, interrupt, idle = values
    user += nice  # user + nice

    # Checkmk defaults: no warn/crit thresholds; always OK if data present
    state = "OK"
    summary = "user %d%%, sys %d%%, interrupt %d%%, idle %d%%" % (user, system, interrupt, idle)

    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {"user": user, "system": system, "interrupt": interrupt}, "details": ""}}
