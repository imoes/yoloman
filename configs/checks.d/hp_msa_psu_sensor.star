def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        discovery = []
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.232.16.1.3"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "host not found", "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        psu_data = {}
        for line in lines:
            parts = line.split()
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            idx = oid[len(".1.3.6.1.4.1.232.16.1.3") + 1:]
            if idx not in psu_data:
                psu_data[idx] = {}
            psu_data[idx]["dc12v"] = value
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.232.16.1.4"], mutates=False)
        if res2.rc == 0:
            for line in res2.stdout.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                oid = parts[0]
                value = parts[1]
                idx = oid[len(".1.3.6.1.4.1.232.16.1.4") + 1:]
                if idx not in psu_data:
                    psu_data[idx] = {}
                psu_data[idx]["dc5v"] = value
        res3 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.232.16.1.5"], mutates=False)
        if res3.rc == 0:
            for line in res3.stdout.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                oid = parts[0]
                value = parts[1]
                idx = oid[len(".1.3.6.1.4.1.232.16.1.5") + 1:]
                if idx not in psu_data:
                    psu_data[idx] = {}
                psu_data[idx]["dc33v"] = value
        res4 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.232.16.1.6"], mutates=False)
        if res4.rc == 0:
            for line in res4.stdout.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                oid = parts[0]
                value = parts[1]
                idx = oid[len(".1.3.6.1.4.1.232.16.1.6") + 1:]
                if idx not in psu_data:
                    psu_data[idx] = {}
                psu_data[idx]["dc12i"] = value
        res5 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.232.16.1.7"], mutates=False)
        if res5.rc == 0:
            for line in res5.stdout.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                oid = parts[0]
                value = parts[1]
                idx = oid[len(".1.3.6.1.4.1.232.16.1.7") + 1:]
                if idx not in psu_data:
                    psu_data[idx] = {}
                psu_data[idx]["dc5i"] = value
        res6 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.232.16.1.8"], mutates=False)
        if res6.rc == 0:
            for line in res6.stdout.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                oid = parts[0]
                value = parts[1]
                idx = oid[len(".1.3.6.1.4.1.232.16.1.8") + 1:]
                if idx not in psu_data:
                    psu_data[idx] = {}
                psu_data[idx]["dctemp"] = value
        indicators = ["dc12v", "dc5v", "dc33v", "dc12i", "dc5i", "dctemp"]
        for idx in sorted(psu_data.keys()):
            data = psu_data[idx]
            has_valid = False
            for i in indicators:
                if data.get(i) != None and data.get(i) != "0":
                    has_valid = True
                    break
            if has_valid:
                metrics = []
                if data.get("dc12v") != None and data.get("dc12v") != "0":
                    metrics.append("voltage_12v")
                if data.get("dc5v") != None and data.get("dc5v") != "0":
                    metrics.append("voltage_5v")
                if data.get("dc33v") != None and data.get("dc33v") != "0":
                    metrics.append("voltage_33v")
                if data.get("dctemp") != None and data.get("dctemp") != "0":
                    metrics.append("temperature")
                discovery.append({"item": idx, "params": {}, "metrics": metrics})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.232.16.1.3." + item], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no such PSU: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dc12v = res.stdout
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.232.16.1.4." + item], mutates=False)
    dc5v = res.stdout if res.rc == 0 else "0"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.232.16.1.5." + item], mutates=False)
    dc33v = res.stdout if res.rc == 0 else "0"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.232.16.1.8." + item], mutates=False)
    dctemp = res.stdout if res.rc == 0 else "0"
    metrics = {}
    details = ""
    state = "OK"
    p12_lower = params.get("levels_12v_lower", (11.9, 11.8))
    p12_upper = params.get("levels_12v_upper", (12.1, 12.2))
    p5_lower = params.get("levels_5v_lower", (4.9, 4.8))
    p5_upper = params.get("levels_5v_upper", (5.1, 5.2))
    p33_lower = params.get("levels_33v_lower", (3.25, 3.20))
    p33_upper = params.get("levels_33v_upper", (3.4, 3.45))
    psu_types = [
        ("dc12v", "12 V", p12_lower, p12_upper),
        ("dc5v", "5 V", p5_lower, p5_upper),
        ("dc33v", "3.3 V", p33_lower, p33_upper),
    ]
    for psu_type, psu_type_readable, lower_params, upper_params in psu_types:
        data_val = dc12v if psu_type == "dc12v" else (dc5v if psu_type == "dc5v" else dc33v)
        if data_val != "0":
            v = float(data_val) / 100
            metric_key = "voltage_" + ("12v" if psu_type == "dc12v" else ("5v" if psu_type == "dc5v" else "33v"))
            metrics[metric_key] = v
            details = details + "%s: %f V" % (psu_type_readable, v) + "\n"
            lower_warn, lower_crit = lower_params
            upper_warn, upper_crit = upper_params
            if v <= lower_crit:
                state = "CRIT"
            elif v <= lower_warn:
                if state != "CRIT":
                    state = "WARN"
            if v >= upper_crit:
                state = "CRIT"
            elif v >= upper_warn:
                if state != "CRIT":
                    state = "WARN"
    if dctemp != "0":
        v = float(dctemp)
        metrics["temperature"] = v
        details = details + "Temp: %f C" % v + "\n"
    return {"changed": False, "msg": "PSU %s voltage check" % item, "data": {"state": state, "metrics": metrics, "details": details}}