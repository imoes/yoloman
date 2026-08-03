def main(ctx, params):
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.20884.2.4.1"
        col_4 = base + ".4"
        res = ctx.run(
            ["snmpwalk", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), col_4],
            mutates=False,
        )
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"discovery": [], "host_labels": {}}}

        entries = []
        seen = set()
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:].strip().strip('"')
            if not oid.startswith(col_4 + "."):
                continue
            index = oid[len(col_4) + 1:]
            if not index:
                continue
            if index in seen:
                continue
            seen.add(index)
            entries.append({
                "item": value,
                "params": {},
                "metrics": ["module_status", "board_status", "power_supply_status"],
            })

        return {"changed": False,
                "msg": "discovered %d tape library modules" % len(entries),
                "data": {"discovery": entries}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.20844.2.4.1"
    col_4 = base + ".4"
    col_5 = base + ".5"
    col_6 = base + ".6"

    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["snmpwalk", "-v2c",
         "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), col_4],
        mutates=False,
    )
    if res.rc == 127:
        return {"changed": False, "msg": "snmpwalk not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:].strip().strip('"')
        if oid.startswith(col_4 + ".") and value == item:
            index = oid[len(col_4) + 1:]
            break

    if index == None or index == "":
        return {"changed": False, "msg": "module %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def get_scalar(col_oid):
        r = ctx.run(
            ["snmpget", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), col_oid + "." + index],
            mutates=False,
        )
        if r.rc != 0:
            return None
        return r.stdout.strip().strip('"')

    module_status = get_scalar(col_5)
    board_status = get_scalar(col_6)
    power_status = get_scalar(base + ".4")

    def to_state(s):
        return "OK" if (s != None and s.lower() == "ok") else "CRIT"

    summary = "Module: %s, Board: %s, Power supply: %s" % (
        module_status, board_status, power_status)

    return {"changed": False, "msg": summary,
            "data": {"state": to_state(module_status), "metrics": {}, "details": ""}}