def _to_celsius(temp_val, unit):
    unit = unit.lower()
    if unit == "c":
        return temp_val
    if unit == "f":
        return (temp_val - 32.0) * 5.0 / 9.0
    if unit == "k":
        return temp_val - 273.15
    return temp_val


def _render_temp(val, unit):
    unit_lower = unit.lower()
    if unit_lower == "c":
        return "%f" % val
    if unit_lower == "f":
        return "%f" % val
    if unit_lower == "k":
        return "%f" % val
    return str(val)


def _safe_float_parse(raw):
    s = raw.strip()
    if not s:
        return (0.0, "C")
    unit = s[-1:].lower()
    num = s[:-1]
    f = float(num) if num.lstrip("-").replace(".", "").isdigit() else 0.0
    return (f, unit)


def main(ctx, params):
    if params.get("_discover"):
        sys_descr = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sys_descr.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"discovery": []}}
        if sys_descr.rc != 0:
            return {"changed": False, "msg": "no SNMP (rc=%d)" % sys_descr.rc,
                    "data": {"discovery": []}}
        descr = sys_descr.stdout.strip()
        is_2930m = False
        for token in descr.split():
            if token.find("Aruba") != -1 and token.find("2930M") != -1:
                is_2930m = True
                break
        if not is_2930m:
            return {"changed": False, "msg": "not Aruba 2930M",
                    "data": {"discovery": []}}

        exists = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.1"],
            mutates=False,
        )
        if exists.rc != 0:
            return {"changed": False, "msg": "no chassis temp data",
                    "data": {"discovery": []}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.2"],
            mutates=False,
        )
        if walk.rc != 0 or not walk.stdout:
            return {"changed": False, "msg": "empty walk",
                    "data": {"discovery": []}}

        seen = {}
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip().strip('"')
            idx = oid[len(".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.2") + 1:]
            if idx not in seen:
                seen[idx] = val

        discovery = []
        for idx in sorted(seen.keys()):
            name = seen[idx]
            discovery.append({"item": "%s %s" % (name, idx),
                              "params": {"levels": (50.0, 60.0)},
                              "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d chassis temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    idx = item.split(" ")[-1] if item else ""
    base = ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1"

    name_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + ".2." + idx],
        mutates=False,
    )
    curr_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + ".3." + idx],
        mutates=False,
    )
    max_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + ".4." + idx],
        mutates=False,
    )
    min_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + ".5." + idx],
        mutates=False,
    )
    thresh_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + ".7." + idx],
        mutates=False,
    )
    avg_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + ".8." + idx],
        mutates=False,
    )

    if curr_res.rc != 0 or not curr_res.stdout.strip():
        return {"changed": False, "msg": "no current temp for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    curr_raw = curr_res.stdout.strip()
    curr_val, dev_unit = _safe_float_parse(curr_raw)
    curr_c = _to_celsius(curr_val, dev_unit)

    warn = 50.0
    crit = 60.0
    levels = params.get("levels")
    if levels:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn", 50.0)
        crit = params.get("crit", 60.0)

    if curr_c >= crit:
        state = "CRIT"
    elif curr_c >= warn:
        state = "WARN"
    else:
        state = "OK"

    details = "Item: %s\nCurrent: %s °C\n" % (
        item, _render_temp(curr_c, "C"))
    if max_res.rc == 0 and max_res.stdout.strip():
        mv = max_res.stdout.strip()
        fval, unit = _safe_float_parse(mv)
        details += "Max: %s °C\n" % _render_temp(_to_celsius(fval, unit), "C")
    if min_res.rc == 0 and min_res.stdout.strip():
        mv = min_res.stdout.strip()
        fval, unit = _safe_float_parse(mv)
        details += "Min: %s °C\n" % _render_temp(_to_celsius(fval, unit), "C")
    if avg_res.rc == 0 and avg_res.stdout.strip():
        av = avg_res.stdout.strip()
        fval, unit = _safe_float_parse(av)
        details += "Average: %s °C\n" % _render_temp(_to_celsius(fval, unit), "C")
    if thresh_res.rc == 0 and thresh_res.stdout.strip():
        tv = thresh_res.stdout.strip()
        fval, unit = _safe_float_parse(tv)
        details += "Threshold: %s °C\n" % _render_temp(_to_celsius(fval, unit), "C")

    msg = "%s: %f°C" % (item, curr_c)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"temperature": curr_c},
                     "details": details}}