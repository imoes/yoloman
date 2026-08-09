def _snmpget(ctx, community, host, oid):
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c",
            community,
            "-Oqv",
            host,
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpwalk(ctx, community, host, oid):
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            community,
            "-Oqn",
            host,
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return []
    return res.stdout.splitlines()


def _sys_oid(ctx, community, host):
    return _snmpget(ctx, community, host, ".1.3.6.1.2.1.1.2.0")


def _detect_ats(ctx, community, host):
    oid = _sys_oid(ctx, community, host)
    if oid == None:
        return False
    return (
        oid == ".1.3.6.1.4.1.318.1.3.11"
        or oid == ".1.3.6.1.4.1.318.1.3.32"
        or oid == ".1.3.6.1.4.1.318.1.3.38"
    )


def _walk_table(ctx, community, host, column_oid):
    rows = {}
    for line in _snmpwalk(ctx, community, host, column_oid):
        sp = line.find(" ")
        if sp < 0:
            continue
        oid_full = line[:sp]
        value = line[sp + 1:]
        if not oid_full.startswith(column_oid):
            continue
        index = oid_full[len(column_oid) + 1:]
        rows[index] = value
    return rows


def _grade(value, warn, crit, upper):
    if warn != None and crit != None:
        if upper:
            if value >= crit:
                return "CRIT"
            if value >= warn:
                return "WARN"
        else:
            if value <= crit:
                return "CRIT"
            if value <= warn:
                return "WARN"
    return "OK"


def _worse(acc, s):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(s, 3) > order.get(acc["state"], 0):
        acc["state"] = s


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        if not _detect_ats(ctx, community, host):
            return {
                "changed": False,
                "msg": "no APC ATS device detected",
                "data": {"discovery": []},
            }

        base = ".1.3.6.1.4.1.318.1.1.8.5.4.3.1"
        voltage_col = base + ".1"
        current_col = base + ".3"
        perc_load_col = base + ".4"
        power_col = base + ".10"

        voltage_rows = _walk_table(ctx, community, host, voltage_col)
        current_rows = _walk_table(ctx, community, host, current_col)
        perc_load_rows = _walk_table(ctx, community, host, perc_load_col)
        power_rows = _walk_table(ctx, community, host, power_col)

        all_indices = set(voltage_rows) | set(current_rows) | set(perc_load_rows) | set(power_rows)

        discovery = []
        for idx in sorted(all_indices):
            discovery.append({
                "item": idx,
                "params": {},
                "metrics": ["volt", "watt", "current", "load_perc"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    if not _detect_ats(ctx, community, host):
        return {
            "changed": False,
            "msg": "no APC ATS device detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    base = ".1.3.6.1.4.1.318.1.1.8.5.4.3.1"
    voltage = _snmpget(ctx, community, host, base + ".1." + item)
    current = _snmpget(ctx, community, host, base + ".3." + item)
    perc_load = _snmpget(ctx, community, host, base + ".4." + item)
    power = _snmpget(ctx, community, host, base + ".10." + item)

    if voltage == None and current == None and perc_load == None and power == None:
        return {
            "changed": False,
            "msg": "no data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    details = ""
    acc = {"state": "OK"}

    if voltage != None:
        v = float(voltage) if voltage.replace(".", "", 1).lstrip("-").isdigit() else 0
        metrics["volt"] = v
        details = details + "Voltage: %f V\n" % v
        wu = params.get("output_voltage_max", None)
        wl = params.get("output_voltage_min", None)
        if wu != None:
            _worse(acc, _grade(v, wu[0], wu[1], True))
        if wl != None:
            _worse(acc, _grade(v, wl[0], wl[1], False))

    if power != None:
        p = float(power) if power.replace(".", "", 1).lstrip("-").isdigit() else 0
        metrics["watt"] = p
        details = details + "Power: %f W\n" % p
        wu = params.get("output_power_max", None)
        wl = params.get("output_power_min", None)
        if wu != None:
            _worse(acc, _grade(p, wu[0], wu[1], True))
        if wl != None:
            _worse(acc, _grade(p, wl[0], wl[1], False))

    if current != None:
        c = float(current) if current.replace(".", "", 1).lstrip("-").isdigit() else 0
        c = c * 0.1
        metrics["current"] = c
        details = details + "Current: %f A\n" % c
        wu = params.get("output_current_max", None)
        wl = params.get("output_current_min", None)
        if wu != None:
            _worse(acc, _grade(c, wu[0], wu[1], True))
        if wl != None:
            _worse(acc, _grade(c, wl[0], wl[1], False))

    if perc_load != None:
        pl = float(perc_load) if perc_load.replace(".", "", 1).lstrip("-").isdigit() else 0
        if pl != -1:
            metrics["load_perc"] = pl
            details = details + "Load: %f%%\n" % pl
            wu = params.get("load_perc_max", None)
            wl = params.get("load_perc_min", None)
            if wu != None:
                _worse(acc, _grade(pl, wu[0], wu[1], True))
            if wl != None:
                _worse(acc, _grade(pl, wl[0], wl[1], False))

    summary = "Phase %s output" % item
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": acc["state"], "metrics": metrics, "details": details.rstrip()},
    }