def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.7244.1.1.1.3.2.4.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    version = params.get("snmp_version", "2c")

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, base_oid + ".1"],
            mutates=False,
        )
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": []}}
        entries = []
        seen = {}
        for line in res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid, _ = sp
            if not oid.startswith(base_oid + ".1."):
                continue
            index = oid[len(base_oid) + 2:]
            if not index or index in seen:
                continue
            seen[index] = True
            entries.append({"item": index, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d power modules" % len(entries),
                "data": {"discovery": entries}}

    item = params.get("item", "")

    # Gather the three columns (status, product name) for the requested index.
    col_status = base_oid + ".2"
    col_product = base_oid + ".4"

    # productName (col 4) first for display.
    res_name = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host,
         col_product + "." + item],
        mutates=False,
    )
    if res_name.rc != 0:
        return {"changed": False, "msg": "no such power module: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # product_name may come back quoted; strip a surrounding pair of quotes.
    product_name = res_name.stdout.strip()
    if len(product_name) >= 2 and product_name[0] == '"' and product_name[-1] == '"':
        product_name = product_name[1:-1]

    res_status = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host,
         col_status + "." + item],
        mutates=False,
    )
    if res_status.rc != 0:
        return {"changed": False,
                "msg": "could not read status for power module " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = res_status.stdout.strip()
    power_status = {
        "1": ("unknown", "OK"),
        "2": ("ok", "OK"),
        "3": ("not-present", "CRIT"),
        "4": ("error", "CRIT"),
        "5": ("critical", "CRIT"),
        "6": ("off", "CRIT"),
        "7": ("dummy", "CRIT"),
        "8": ("fanmodule", "OK"),
    }
    if status not in power_status:
        return {"changed": False,
                "msg": "unknown power module status code: " + status,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_readable, state = power_status[status]
    return {"changed": False,
            "msg": "[%s] Status: %s" % (product_name, state_readable),
            "data": {"state": state,
                     "metrics": {},
                     "details": ""}}