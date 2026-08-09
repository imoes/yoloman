def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if params.get("_discover"):
        sysid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysid.rc != 0 or not sysid.stdout:
            return {"changed": False, "msg": "no FortiGate detected", "data": {"discovery": []}}
        sysid_val = sysid.stdout.strip()
        if not sysid_val.startswith(".1.3.6.1.4.1.12356.101.1."):
            return {"changed": False, "msg": "no FortiGate detected", "data": {"discovery": []}}

        walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.12356.101.4.3.2.1.2"], mutates=False)
        if walk.rc != 0 or not walk.stdout:
            return {"changed": False, "msg": "no FortiGate sensors found", "data": {"discovery": []}}

        rows = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid_parts = parts[0].split(".")
            idx = oid_parts[-1]
            rows.append(idx)

        total = 0
        for idx in rows:
            val_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12356.101.4.3.2.1.3." + idx], mutates=False)
            if val_res.rc == 0 and val_res.stdout and val_res.stdout.strip() != "0":
                total = total + 1

        if total < 1:
            return {"changed": False, "msg": "no FortiGate sensors found", "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["sensors", "sensors_ok", "sensors_alarm"]}]}}

    sysid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysid.rc != 0 or not sysid.stdout:
        return {"changed": False, "msg": "no FortiGate detected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysid_val = sysid.stdout.strip()
    if not sysid_val.startswith(".1.3.6.1.4.1.12356.101.1."):
        return {"changed": False, "msg": "no FortiGate detected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.12356.101.4.3.2.1.2"], mutates=False)
    if walk.rc != 0 or not walk.stdout:
        return {"changed": False, "msg": "no FortiGate sensors found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = []
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid_parts = parts[0].split(".")
        idx = oid_parts[-1]
        rows.append(idx)

    sensors = []
    for idx in rows:
        name_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12356.101.4.3.2.1.2." + idx], mutates=False)
        val_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12356.101.4.3.2.1.3." + idx], mutates=False)
        status_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12356.101.4.3.2.1.4." + idx], mutates=False)
        name = name_res.stdout.strip() if name_res.rc == 0 and name_res.stdout else ""
        value = val_res.stdout.strip() if val_res.rc == 0 and val_res.stdout else ""
        status = status_res.stdout.strip() if status_res.rc == 0 and status_res.stdout else ""
        sensors.append(name + "|" + value + "|" + status)

    total = 0
    critical_count = 0
    critical_names = []
    for entry in sensors:
        fields = entry.split("|")
        name = fields[0]
        value = fields[1]
        status = fields[2]
        if value != "0":
            total = total + 1
            if status == "1":
                critical_count = critical_count + 1
                critical_names.append(name)

    if total < 1:
        return {"changed": False, "msg": "no FortiGate sensors found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ok = total - critical_count

    lines = []
    lines.append("%d sensors" % total)
    lines.append("%d OK" % ok)
    lines.append("%d with alarm" % critical_count)
    for sensor in critical_names:
        lines.append(sensor)

    details = "\n".join(lines)
    state = "CRIT" if critical_count > 0 else "OK"
    msg = "%d sensors" % total
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"sensors": total, "sensors_ok": ok, "sensors_alarm": critical_count},
                     "details": details}}