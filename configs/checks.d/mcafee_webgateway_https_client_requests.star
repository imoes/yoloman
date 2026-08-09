def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-Oqv", "-t", "5", "-r", "1",
                       params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "host is not a Skyhigh Secure Web Gateway",
                    "data": {"discovery": []}}
        sysoid_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                              "-Oqv", "-t", "5", "-r", "1", params.get("host", "localhost"),
                              ".1.3.6.1.2.1.1.2.0"], mutates=False)
        sys_oid = ""
        if sysoid_res.rc == 0:
            sys_oid = sysoid_res.stdout.strip()
        is_webgateway = ("skyhigh secure web gateway" in res.stdout.lower() or
                         sys_oid == "1.3.6.1.4.1.59732.2.7.1.1")
        if not is_webgateway:
            return {"changed": False, "msg": "host is not a Skyhigh Secure Web Gateway",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.4.1.59732.2.7.2"
        oids = ["2.1", "3.1", "6.1"]
        walk_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", "-t", "5", "-r", "1", params.get("host", "localhost"),
                            base + ".2.1", base + ".3.1", base + ".6.1"], mutates=False)
        if walk_res.rc != 0:
            return {"changed": False, "msg": "could not fetch web gateway client request OIDs",
                    "data": {"discovery": []}}
        vals = walk_res.stdout.strip().split("\n")
        http_val = vals[0].strip() if len(vals) > 0 and vals[0].strip().isdigit() else None
        httpv2_val = vals[1].strip() if len(vals) > 1 and vals[1].strip().isdigit() else None
        https_val = vals[2].strip() if len(vals) > 2 and vals[2].strip().isdigit() else None
        http = int(http_val) if http_val else None
        httpv2 = int(httpv2_val) if httpv2_val else None
        https = int(https_val) if https_val else None
        items = []
        if http:
            items.append({"item": "", "params": {}, "metrics": ["requests_per_second"]})
        if https:
            items.append({"item": "", "params": {}, "metrics": ["requests_per_second"]})
        if httpv2:
            items.append({"item": "", "params": {}, "metrics": ["requests_per_second"]})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.59732.2.7.2"
    oid_map = {"http": "2.1", "https": "6.1", "httpv2": "3.1"}
    oid = base + "." + oid_map.get(item, "6.1")
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-Oqv", "-t", "5", "-r", "1", params.get("host", "localhost"), oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "could not fetch %s client request OID" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    if not raw.isdigit():
        return {"changed": False, "msg": "no valid %s client request counter" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = int(raw)
    metric_name = "requests_per_second"
    warn = params.get("warn", 500)
    crit = params.get("crit", 1000)
    rate = value
    state = "CRIT" if rate >= crit else ("WARN" if rate >= warn else "OK")
    return {"changed": False, "msg": "%s %s requests/s" % (item, "%f" % rate),
            "data": {"state": state, "metrics": {metric_name: rate}, "details": ""}}