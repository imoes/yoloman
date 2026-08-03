def main(ctx, params):
    base_oid = ".1.3.6.1.2.1.1.2.0"
    sys_oid = ".1.3.6.1.4.1.20246"
    col_oid = ".1.3.6.1.4.1.20246.2.3.1.1.1.2.5.2.2"

    if params.get("_discover"):
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Ov", params.get("host", "localhost"), base_oid],
            mutates=False,
        )
        if sys_res.rc != 0 or not sys_res.stdout.startswith(sys_oid):
            return {"changed": False, "msg": "device not an Orion",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), col_oid + ".1"],
            mutates=False,
        )
        if walk.rc != 0 or not walk.stdout:
            return {"changed": False, "msg": "no battery test data",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered battery test",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}]}}

    item = params.get("item", "")
    date_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), col_oid + ".1.1"],
        mutates=False,
    )
    result_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), col_oid + ".2.1"],
        mutates=False,
    )
    if date_res.rc != 0 or result_res.rc != 0:
        return {"changed": False, "msg": "no battery test data",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}

    last_test_date = date_res.stdout.strip()
    test_result = result_res.stdout.strip()

    map_states = {
        "1": ("OK", "none"),
        "2": ("CRIT", "failed"),
        "3": ("WARN", "aborted"),
        "4": ("CRIT", "load failure"),
        "5": ("OK", "OK"),
        "6": ("WARN", "aborted manual"),
        "7": ("WARN", "aborted ev ctrl charge"),
        "8": ("WARN", "aborted inhibit ev"),
    }

    entry = map_states.get(test_result)
    if test_result != "1":
        if entry == None:
            state = "UNKNOWN"
            readable = "unknown[%s]" % test_result
        else:
            state = entry[0]
            readable = entry[1]
        msg = "Last performed: %s, Result: %s" % (last_test_date, readable)
    else:
        state = "OK"
        msg = "No test result available"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}