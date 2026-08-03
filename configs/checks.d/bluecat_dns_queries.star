def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = "1.3.6.1.4.1.13315.3.1.2.2.2.1"
    oids = ["1", "2", "3", "4", "5", "6"]
    value_names = ["Success", "Referral", "NXRSet", "NXDomain", "Recursion", "Failure"]

    if params.get("_discover"):
        sys_oid = ".1.3.6.1.2.1.1.2.0"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no bluecat device found", "data": {"discovery": []}}
        sys_res = res.stdout.strip()
        if sys_res != ".1.3.6.1.4.1.13315.2.1":
            return {"changed": False, "msg": "no bluecat device found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": value_names}]}}

    item = params.get("item", "")
    values = []
    for oid in oids:
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "unable to fetch bluecat dns queries",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        values.append(res.stdout.strip())

    if len(values) < len(value_names):
        return {"changed": False, "msg": "incomplete data from bluecat device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    detail_parts = []
    for i in range(len(value_names)):
        name = value_names[i]
        value = values[i]
        num = int(value) if value.isdigit() else 0
        detail_parts.append("%s: %d" % (name, num))
        if num > 0:
            metrics[name] = float(num)

    detail = ", ".join(detail_parts)
    return {"changed": False, "msg": "DNS Queries " + detail,
            "data": {"state": "OK", "metrics": metrics, "details": detail}}