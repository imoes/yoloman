def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0:
            return {"changed": False, "msg": "not a kentix device", "data": {"discovery": []}}
        if not sys_oid.stdout.startswith(".1.3.6.1.4.1.332.11.6"):
            return {"changed": False, "msg": "not a kentix device", "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.37954.1.2"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}
        sensors = {}
        for line in res.stdout.splitlines():
            idx = line.find(" ")
            if idx < 0:
                continue
            oid = line[:idx]
            val = line[idx + 1:]
            cols = oid.split(".")
            if len(cols) < 13:
                continue
            suffix = cols[12]
            col_map = {"2": "name", "3": "temp", "4": "humidity", "5": "dew", "6": "co", "7": "motion", "8": "digital1", "9": "digital2", "10": "digitalout", "11": "comerr"}
            col = col_map.get(suffix)
            if col == "name":
                sensors[val] = {"name": val}
            else:
                for s in sensors.values():
                    pass
        discovery = []
        for name in sorted(sensors):
            discovery.append({"item": name, "params": {"warn": 80, "crit": 90}, "metrics": ["temperature"]})
            discovery.append({"item": name, "params": {"levels": (30, 50)}, "metrics": ["humidity"]})
            discovery.append({"item": name, "params": {"levels": (1.0, 5.0)}, "metrics": ["smoke"]})
            discovery.append({"item": name, "metrics": ["leakage"]})
        return {"changed": False, "msg": "discovered %d sensors" % len(sensors), "data": {"discovery": discovery}}

    item = params.get("item", "")
    metric = params.get("_metric", "temperature")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.37954.1.2"
    if metric == "temperature":
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "%s.7.%s" % (base, item)], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no sensor " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        name_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "%s.2.%s" % (base, item)], mutates=False)
        reading = float(res.stdout) / 10
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)
        state = "CRIT" if reading >= crit else ("WARN" if reading >= warn else "OK")
        return {"changed": False, "msg": "%s: %f C" % (name_res.stdout, reading), "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}
    if metric == "humidity":
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "%s.4.%s" % (base, item)], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no sensor " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        reading = float(res.stdout) / 10
        levels = params.get("levels", (30, 50))
        warn = levels[0] if len(levels) > 0 else 30
        crit = levels[1] if len(levels) > 1 else 50
        state = "CRIT" if reading >= crit else ("WARN" if reading >= warn else "OK")
        return {"changed": False, "msg": "%f%% humidity" % reading, "data": {"state": state, "metrics": {"humidity": reading}, "details": ""}}
    if metric == "smoke":
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "%s.6.%s" % (base, item)], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no sensor " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        reading = int(res.stdout)
        levels = params.get("levels", (1.0, 5.0))
        warn = levels[0] if len(levels) > 0 else 1.0
        crit = levels[1] if len(levels) > 1 else 5.0
        state = "CRIT" if reading >= crit else ("WARN" if reading >= warn else "OK")
        return {"changed": False, "msg": "%d%% smoke" % reading, "data": {"state": state, "metrics": {"smoke": reading}, "details": ""}}
    if metric == "leakage":
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "%s.8.%s" % (base, item)], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no sensor " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        reading = int(res.stdout)
        if reading > 0:
            return {"changed": False, "msg": "Alarm or disconnected", "data": {"state": "CRIT", "metrics": {"leakage": reading}, "details": ""}}
        return {"changed": False, "msg": "Connected", "data": {"state": "OK", "metrics": {"leakage": reading}, "details": ""}}
    return {"changed": False, "msg": "unknown metric " + str(metric), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}