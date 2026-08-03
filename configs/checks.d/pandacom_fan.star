def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                       params.get("host", "localhost"),
                       ".1.3.6.1.4.1.3652.3.2.3.1.2"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no pandacom fan data",
                    "data": {"discovery": []}}
        discovery = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            oid_full = f[0]
            value = f[1]
            col_base = ".1.3.6.1.4.1.3652.3.2.3.1.2."
            if not oid_full.startswith(col_base):
                continue
            index = oid_full[len(col_base):]
            if index == "" or value in ["0", "5"]:
                continue
            discovery.append({"item": index, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"),
                   ".1.3.6.1.4.1.3652.3.2.3.1.2." + item], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data for fan %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    map_fan_state = {
        "0": ("UNKNOWN", "not available"),
        "1": ("OK", "on"),
        "2": ("CRIT", "off"),
        "3": ("OK", "pass"),
        "4": ("CRIT", "fail"),
        "5": ("UNKNOWN", "not installed"),
        "6": ("OK", "auto"),
    }
    state_val = res.stdout.strip()
    state, state_readable = map_fan_state.get(state_val, ("UNKNOWN", "unknown (%s)" % state_val))
    return {"changed": False,
            "msg": "Fan %s: Operational status: %s" % (item, state_readable),
            "data": {"state": state, "metrics": {}, "details": ""}}