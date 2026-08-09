def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c",
                       params.get("community", "public"),
                       "-Oqn", params.get("host", "localhost"),
                       "1.3.6.1.4.1.2606.7.4.2.2.1.3.2.1"], mutates=False)
        # probe sysDescr for Rittal LCP
        dres = ctx.run(["snmpget", "-v2c", "-c",
                        params.get("community", "public"),
                        "-Ov", params.get("host", "localhost"),
                        "1.3.6.1.2.1.1.1.0"], mutates=False)
        if not res.stdout or not dres.stdout or dres.rc != 0:
            return {"changed": False, "msg": "no Rittal LCP found",
                    "data": {"discovery": []}}

        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full, value = parts[0], parts[1]
            index = oid_full[len("1.3.6.1.4.1.2606.7.4.2.2.1.3.2.1") + 1:]
            if not index:
                continue
            name_res = ctx.run(["snmpget", "-v2c", "-c",
                                params.get("community", "public"),
                                "-Oqv", params.get("host", "localhost"),
                                "1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6." + index],
                               mutates=False)
            desc = name_res.stdout.strip().strip('"') if name_res.rc == 0 else index
            discovery.append({"item": index, "params": {"_item_key": index,
                                                        "use_sensor_description": False},
                              "metrics": ["current"],
                              "service_labels": {"cmk/description": desc}})
        return {"changed": False,
                "msg": "discovered %d can_current sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    # fetch Status, Value, thresholds via SNMP by index
    base = "1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
    def col(suffix):
        r = ctx.run(["snmpget", "-v2c", "-c",
                     params.get("community", "public"),
                     "-Oqv", params.get("host", "localhost"),
                     base + "." + suffix + "." + item], mutates=False)
        if r.rc != 0:
            return None
        v = r.stdout.strip().strip('"')
        return v

    status = col("4")   # Status
    value_s = col("5")  # Value
    warn_s = col("7")   # SetPtHighWarning
    crit_s = col("8")   # SetPtHighAlarm

    if value_s == None or status == None:
        return {"changed": False, "msg": "sensor not reachable or gone",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def to_num(s):
        if s == None:
            return 0.0
        s = s.strip()
        try_ok = False
        neg = False
        ss = s
        if len(ss) > 0 and ss[0] == "-":
            neg = True
            ss = ss[1:]
        if len(ss) > 0 and ss[0] == "+":
            ss = ss[1:]
        if len(ss) > 0 and ss[len(ss)-1] == ".":
            ss = ss[:len(ss)-1]
        if len(ss) == 0:
            return 0.0
        if "." in ss:
            halves = ss.split(".")
            if len(halves) == 2 and halves[0].isdigit() and halves[1].isdigit():
                n = float(ss)
                return -n if neg else n
            return 0.0
        if ss.isdigit():
            n = float(ss)
            return -n if neg else n
        return 0.0

    value = to_num(value_s)
    warn = to_num(warn_s)
    crit = to_num(crit_s)

    state = "OK" if status == "OK" else "CRIT"
    metric_val = value / 1000.0
    levels = (warn / 1000.0, crit / 1000.0)

    return {"changed": False,
            "msg": "Status: %s, Current: %f mA (warn/crit at %f/%f mA)" %
                   (status, value, warn, crit),
            "data": {"state": state,
                     "metrics": {"current": metric_val},
                     "metric_levels": {"current": levels},
                     "details": "value=%s warn=%s crit=%s" % (value_s, warn_s, crit_s)}}