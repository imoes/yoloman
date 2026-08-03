def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-Oqn", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.2272.1.101.1.1.2.1.1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no VSP switches found",
                    "data": {"discovery": []}}
        desc_by_index = {}
        for line in res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid = sp[0]
            idx = oid[len(".1.3.6.1.4.1.2272.1.101.1.1.2.1.1") + 1:]
            desc_by_index[idx] = sp[1].strip('"')
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.2272.1.101.1.1.2.1.2"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "no VSP switches found",
                    "data": {"discovery": []}}
        out = []
        for line in res2.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid = sp[0]
            idx = oid[len(".1.3.6.1.4.1.2272.1.101.1.1.2.1.2") + 1:]
            val = sp[1].strip()
            try_temp = float(val)
            item = idx
            if idx in desc_by_index and desc_by_index[idx]:
                item = desc_by_index[idx]
            levels = params.get("levels", (50.0, 60.0))
            warn = levels[0]
            crit = levels[1]
            out.append({"item": item, "params": {"levels": levels},
                        "metrics": ["temperature"],
                        "service_labels": {}})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    base1 = ".1.3.6.1.4.1.2272.1.101.1.1"
    res_d = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                     "-Oqn", params.get("host", "localhost"),
                     base1 + ".2.1.1"], mutates=False)
    desc_by_index = {}
    if res_d.rc == 0:
        for line in res_d.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid = sp[0]
            idx = oid[len(base1 + ".2.1.1") + 1:]
            desc_by_index[idx] = sp[1].strip('"')
    res_t = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                     "-Oqn", params.get("host", "localhost"),
                     base1 + ".2.1.2"], mutates=False)
    if res_t.rc != 0 or not res_t.stdout:
        return {"changed": False, "msg": "no temperature data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp_val = None
    found_item = None
    for line in res_t.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid = sp[0]
        idx = oid[len(base1 + ".2.1.2") + 1:]
        candidate = idx
        if idx in desc_by_index and desc_by_index[idx]:
            candidate = desc_by_index[idx]
        if candidate == item or idx == item:
            val = sp[1].strip()
            if val == "NOSUCHOBJECT" or val == "NOSUCHINSTANCE" or val == "ENDOFMIBVIEW":
                continue
            temp_val = float(val)
            found_item = item
            break
    if temp_val == None:
        res_g = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-Oqv", params.get("host", "localhost"), item], mutates=False)
        if res_g.rc != 0:
            return {"changed": False,
                    "msg": "item not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", (50.0, 60.0))
    warn = levels[0]
    crit = levels[1]
    state = "CRIT" if temp_val >= crit else ("WARN" if temp_val >= warn else "OK")
    unit = "C"
    msg = "Temperature: %s %s" % (str(temp_val), unit)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"temperature": temp_val},
                     "details": ""}}