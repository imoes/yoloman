def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-Oqn", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.25506.8.35.9.1.2.1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no hp_hh3c_power data",
                    "data": {"discovery": []}}
        devices = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            value = parts[1].strip()
            idx = oid[len(".1.3.6.1.4.1.25506.8.35.9.1.2.1") + 1:]
            if not idx:
                continue
            num = idx.split(".")[0]
            if num:
                devices[num] = int(value) if value.lstrip("-").isdigit() else 0
        discovery = []
        for num, status in devices.items():
            if status in (3, 4):
                continue
            discovery.append({"item": num, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d devices" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-Oqv", params.get("host", "localhost"),
                   ".1.3.6.1.4.1.25506.8.35.9.1.2.1.%s.2" % item], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no power status for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status_str = res.stdout.strip()
    status = int(status_str) if status_str.lstrip("-").isdigit() else 0
    if status == 2:
        state = "CRIT"
        msg = "Status: deactive"
    elif status == 1:
        state = "OK"
        msg = "Status: active"
    else:
        state = "UNKNOWN"
        msg = "Status: unknown (%d)" % status
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {},
                     "details": "Device %s status %d" % (item, status)}}