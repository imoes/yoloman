def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists("/usr/bin/snmpwalk") and not ctx.file_exists("/usr/bin/snmpget"):
            return {"changed": False, "msg": "no SNMP tools installed", "data": {"discovery": []}}
        sysoid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                          params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysoid.rc != 0 or sysoid.stdout.find(".1.3.6.1.4.1.37447.3.1") != 0:
            return {"changed": False, "msg": "not a Nimble device", "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                       params.get("host", "localhost"), ".1.3.6.1.4.1.37447.1.2.1.2"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no Nimble volumes found", "data": {"discovery": []}}
        names = {}
        online_col = {}
        total_col = {}
        alloc_col = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            idx = oid[len(".1.3.6.1.4.1.37447.1.2.1.2") + 1:]
            names[idx] = val
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                        params.get("host", "localhost"), ".1.3.6.1.4.1.37447.1.2.1.3"], mutates=False)
        if res2.rc == 0:
            for line in res2.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                idx = oid[len(".1.3.6.1.4.1.37447.1.2.1.3") + 1:]
                total_col[idx] = parts[1]
        res3 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                        params.get("host", "localhost"), ".1.3.6.1.4.1.37447.1.2.1.4"], mutates=False)
        if res3.rc == 0:
            for line in res3.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                idx = oid[len(".1.3.6.1.4.1.37447.1.2.1.4") + 1:]
                alloc_col[idx] = parts[1]
        res4 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                        params.get("host", "localhost"), ".1.3.6.1.4.1.37447.1.2.1.6"], mutates=False)
        if res4.rc == 0:
            for line in res4.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                idx = oid[len(".1.3.6.1.4.1.37447.1.2.1.6") + 1:]
                online_col[idx] = parts[1]
        res5 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                        params.get("host", "localhost"), ".1.3.6.1.4.1.37447.1.2.1.10"], mutates=False)
        if res5.rc == 0:
            for line in res5.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                idx = oid[len(".1.3.6.1.4.1.37447.1.2.1.10") + 1:]
                if online_col.get(idx, "0") == "1" and names.get(idx, "").startswith(""):
                    pass
        out = []
        for idx in sorted(names.keys()):
            if online_col.get(idx, "0") != "1":
                continue
            name = names[idx]
            total = total_col.get(idx, "0")
            if not total.isdigit():
                continue
            out.append({"item": name, "params": {"warn": 80, "crit": 90},
                        "metrics": ["used_percent"]})
        return {"changed": False, "msg": "discovered %d volumes" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                   params.get("host", "localhost"), ".1.3.6.1.4.1.37447.1.2.1.2"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no Nimble volumes accessible",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found_idx = None
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[len(".1.3.6.1.4.1.37447.1.2.1.2") + 1:]
        if parts[1] == item:
            found_idx = idx
            break
    if found_idx == None:
        return {"changed": False, "msg": "no such Nimble volume: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    online_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                          params.get("host", "localhost"),
                          ".1.3.6.1.4.1.37447.1.2.1.6." + found_idx], mutates=False)
    if online_res.rc != 0 or online_res.stdout.strip() == "0":
        return {"changed": False, "msg": "Volume is offline!",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    total_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                         params.get("host", "localhost"),
                         ".1.3.6.1.4.1.37447.1.2.1.3." + found_idx], mutates=False)
    alloc_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                         params.get("host", "localhost"),
                         ".1.3.6.1.4.1.37447.1.2.1.4." + found_idx], mutates=False)
    if total_res.rc != 0 or alloc_res.rc != 0:
        return {"changed": False, "msg": "could not gather Nimble volume metrics",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    total_s = total_res.stdout.strip()
    alloc_s = alloc_res.stdout.strip()
    if not total_s.isdigit() or not alloc_s.isdigit():
        return {"changed": False, "msg": "invalid metric values from Nimble",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    total = int(total_s)
    alloc = int(alloc_s)
    free = total - alloc
    used_percent = 0
    if total > 0:
        used_percent = (alloc * 100) // total
    warn = params.get("levels", (80, 90))
    warn_v = warn[0] if type(warn) == "tuple" and len(warn) >= 2 else 80
    crit = params.get("levels_upper", None)
    if crit == None:
        crit_v = warn[1] if type(warn) == "tuple" and len(warn) >= 2 else 90
    else:
        crit_v = crit
    state = "CRIT" if used_percent >= crit_v else ("WARN" if used_percent >= warn_v else "OK")
    return {"changed": False,
            "msg": "%s: %d%% used" % (item, used_percent),
            "data": {"state": state, "metrics": {"used_percent": used_percent, "alloc": alloc, "free": free}, "details": ""}}