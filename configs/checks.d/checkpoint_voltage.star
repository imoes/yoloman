def main(ctx, params):
    if params.get("_discover"):
        if not _is_checkpoint(ctx):
            return {"changed": False, "msg": "no Check Point system found", "data": {"discovery": []}}
        table = _walk_voltage_table(ctx)
        out = []
        for row in table:
            if len(row) >= 4:
                name = row[0]
                if name != "":
                    out.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d voltage sensors" % len(out), "data": {"discovery": out}}
        return {"changed": False, "msg": "no voltage sensors found", "data": {"discovery": []}}

    item = params.get("item", "")
    if not _is_checkpoint(ctx):
        return {"changed": False, "msg": "no Check Point system found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    table = _walk_voltage_table(ctx)
    for row in table:
        if len(row) >= 4 and row[0] == item:
            value = row[1]
            unit = row[2]
            dev_status = row[3]
            state, state_readable = _status_to_cmk(dev_status)
            return {"changed": False, "msg": "Status: %s, %s %s" % (state_readable, value, unit), "data": {"state": state, "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "no such voltage sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


def _is_checkpoint(ctx):
    res = ctx.run(["snmpget", "-v2c", "-c", _community(ctx), "-Oqv", _host(ctx), ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    sysid = res.stdout.strip()
    if sysid.startswith(".1.3.6.1.4.1.2620"):
        return True
    g = ctx.run(["snmpget", "-v2c", "-c", _community(ctx), "-Oqv", _host(ctx), ".1.3.6.1.4.1.2620.1.6.5.1.0"], mutates=False)
    if g.rc == 0 and g.stdout.strip() == "Gaia":
        return True
    return False


def _walk_voltage_table(ctx):
    base = ".1.3.6.1.4.1.2620.1.6.7.8.3.1"
    oids = ["2", "3", "4", "6"]
    rows = {}
    order = []
    for o in oids:
        res = ctx.run(["snmpwalk", "-v2c", "-c", _community(ctx), "-Oqn", _host(ctx), base + "." + o], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            full_oid = parts[0]
            val = parts[1]
            suffix = full_oid[len(base) + 1:]
            if suffix not in rows:
                rows[suffix] = {}
                order.append(suffix)
            rows[suffix][o] = val
    table = []
    for suffix in order:
        row = {}
        for o in oids:
            row[o] = rows[suffix].get(o, "")
        table.append(row)
    return table


def _status_to_cmk(dev_status):
    s = dev_status.strip()
    if s == "0":
        return ("OK", "sensor in range")
    if s == "1":
        return ("CRIT", "sensor out of range")
    if s == "2":
        return ("UNKNOWN", "reading error")
    return ("UNKNOWN", "unknown sensor status")


def _host(ctx):
    return "localhost"


def _community(ctx):
    return "public"