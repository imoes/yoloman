def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.7244.1.1.1.3.3.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "snmpwalk not available or unreachable", "data": {"discovery": []}}
        table = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            idx = oid[len(base) + 1:]
            col = oid[len(base) + 1:].rsplit(".", 1)[0] if "." in oid[len(base) + 1:] else ""
            if idx not in table:
                table[idx] = {}
            table[idx][col] = val
        out = []
        for idx in sorted(table.keys()):
            row = table[idx]
            status = row.get("2", "")
            descr = row.get("3", "")
            if status == "8":
                continue
            out.append({"item": descr, "params": {"levels": (80.0, 90.0), "levels_lower": (20.0, 10.0)}, "metrics": ["perc", "rpm"]})
        return {"changed": False, "msg": "discovered %d fans" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.7244.1.1.1.3.3.1.1"
    cols = ["2", "3", "4", "5", "6", "7"]
    row = {}
    for col in cols:
        oid = base + "." + col
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "snmp not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        row[col] = res.stdout.strip().strip('"')
    if not row.get("2"):
        return {"changed": False, "msg": "no blade bx powerfan data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    descr = row.get("3", "")
    if descr != item:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = row.get("2", "")
    rpm_s = row.get("4", "")
    max_speed_s = row.get("5", "")
    ctrlstate = row.get("7", "")

    _BLADE_BX_STATUS = {"1": "unknown", "2": "disabled", "3": "ok", "4": "fail", "5": "prefailure-predicted", "6": "redundant-fan-failed", "7": "not-manageable", "8": "not-present", "9": "not-available"}

    if ctrlstate != "2":
        rpm = 0
        speed_perc = 0.0
        if max_speed_s and max_speed_s.isdigit() and rpm_s and rpm_s.isdigit():
            rpm = float(rpm_s)
            speed_perc = rpm * 100.0 / float(max_speed_s)
        return {"changed": False, "msg": "Fan not present or poweroff", "data": {"state": "CRIT", "metrics": {"perc": speed_perc, "rpm": rpm}, "details": ""}}

    if status != "3":
        rpm = 0.0
        speed_perc = 0.0
        if max_speed_s and max_speed_s.isdigit() and rpm_s and rpm_s.isdigit():
            rpm = float(rpm_s)
            speed_perc = rpm * 100.0 / float(max_speed_s)
        st = _BLADE_BX_STATUS.get(status, "unknown")
        return {"changed": False, "msg": "Status: " + st, "data": {"state": "CRIT", "metrics": {"perc": speed_perc, "rpm": rpm}, "details": ""}}

    if not rpm_s or not max_speed_s or not rpm_s.isdigit() or not max_speed_s.isdigit():
        return {"changed": False, "msg": "could not read fan speed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rpm = float(rpm_s)
    max_speed = float(max_speed_s)
    speed_perc = rpm * 100.0 / max_speed if max_speed > 0 else 0.0

    levels_lower = params.get("levels_lower", (20.0, 10.0))
    levels_upper = params.get("levels", (80.0, 90.0))
    lc_warn = levels_lower[0]
    lc_crit = levels_lower[1]
    uc_warn = levels_upper[0]
    uc_crit = levels_upper[1]

    state = "OK"
    if speed_perc <= lc_crit or speed_perc >= uc_crit:
        state = "CRIT"
    elif speed_perc <= lc_warn or speed_perc >= uc_warn:
        state = "WARN"

    msg = "%f%% (Speed at %d RPM)" % (speed_perc, int(rpm))
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"perc": speed_perc, "rpm": rpm}, "details": ""}}