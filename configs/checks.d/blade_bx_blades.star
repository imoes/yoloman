def main(ctx, params):
    if params.get("_discover"):
        # Probe: is this a Blade BX device? We detect via the SNMP table itself.
        base_oid = "1.3.6.1.4.1.7244.1.1.1.4.2.1.1"
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", "-OQ", params.get("host", "localhost"), base_oid + ".1"],
            mutates=False,
        )
        if res.rc != 0 and res.rc != 126:  # 126=empty/noSuchObject from some agents; absent=127
            return {"changed": False, "msg": "snmp unreachable", "data": {"discovery": []}}
        if res.rc == 127 or not res.stdout.strip():
            return {"changed": False, "msg": "no Blade BX blades detected",
                    "data": {"discovery": []}}

        # Fetch columns: id(.1), status(.2), serial(.5), name(.21)
        ids = _walk_col(ctx, params, base_oid + ".1")
        statuses = _walk_col(ctx, params, base_oid + ".2")
        serials = _walk_col(ctx, params, base_oid + ".5")
        names = _walk_col(ctx, params, base_oid + ".21")
        if not ids:
            return {"changed": False, "msg": "no Blade BX blades detected",
                    "data": {"discovery": []}}

        out = []
        for idx, idv in ids.items():
            st = statuses.get(idx, "3")
            if st != "3":  # status 3 = blade not present -> no service
                out.append({"item": idv, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d Blade BX blades" % len(out),
                "data": {"discovery": out,
                         "host_labels": {"cmk/blade_bx": "true"}}}

    # CHECK MODE for one item
    item = params.get("item", "")
    base_oid = "1.3.6.1.4.1.7244.1.1.1.4.2.1.1"
    idv = _get_scalar(ctx, params, base_oid + ".1." + item)
    st = _get_scalar(ctx, params, base_oid + ".2." + item)
    serial = _get_scalar(ctx, params, base_oid + ".5." + item)
    name = _get_scalar(ctx, params, base_oid + ".21." + item)
    if not idv and not st:
        return {"changed": False,
                "msg": "blade %s not present" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_codes = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("OK", "OK"),
        "3": ("UNKNOWN", "not present"),
        "4": ("CRIT", "error"),
        "5": ("CRIT", "critical"),
        "6": ("OK", "standby"),
    }
    state, readable = status_codes.get(st, ("UNKNOWN", "unknown"))
    if name:
        name_info = "[%s, Serial: %s]" % (name, serial)
    else:
        name_info = "[Serial: %s]" % serial
    msg = "%s Status: %s" % (name_info, readable)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}


def _walk_col(ctx, params, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", "-OQ", params.get("host", "localhost"), oid],
        mutates=False,
    )
    out = {}
    if res.rc != 0 or not res.stdout.strip():
        return out
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        left = line[:sp]
        val = line[sp + 1:].strip()
        dot = left.rfind(".")
        if dot < 0:
            continue
        idx = left[dot + 1:]
        out[idx] = val
    return out


def _get_scalar(ctx, params, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", "-OQ", params.get("host", "localhost"), oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return ""
    return res.stdout.strip()