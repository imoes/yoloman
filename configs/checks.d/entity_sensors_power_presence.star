def _is_int(s):
    if s == None or s == "":
        return False
    sign = 0
    body = s
    if body[0] == "-" or body[0] == "+":
        sign = 1
        body = body[1:]
    if body == "":
        return False
    for ch in body:
        if ch < "0" or ch > "9":
            return False
    return True

def main(ctx, params):
    if params.get("_discover"):
        discovery = []
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        names = {}
        names_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.47.1.1.1.1.7"],
            mutates=False,
        )
        if names_res.rc == 0 and names_res.stdout != "":
            for line in names_res.stdout.splitlines():
                sp = line.find(" ")
                if sp <= 0:
                    continue
                oid = line[:sp]
                val = line[sp + 1:]
                names[oid] = val

        sensor_type_oid = ".1.3.6.1.2.1.99.1.1.1.1.1"
        sensor_type_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, sensor_type_oid],
            mutates=False,
        )
        if sensor_type_res.rc == 0 and sensor_type_res.stdout != "":
            for line in sensor_type_res.stdout.splitlines():
                sp = line.find(" ")
                if sp <= 0:
                    continue
                oid = line[:sp]
                val = line[sp + 1:]
                idx = oid[len(sensor_type_oid) + 1:]
                if idx == "":
                    continue

                power_oid = ".1.3.6.1.2.1.99.1.1.1.2." + idx
                power_res = ctx.run(
                    ["snmpget", "-v2c", "-c", community, "-Oqv", host, power_oid],
                    mutates=False,
                )
                if power_res.rc != 0 or power_res.stdout == "":
                    continue

                type_body = power_res.stdout.strip()
                t = type_body.split(":")
                rtype = ""
                if len(t) > 1:
                    rtype = t[1].strip()
                else:
                    rtype = type_body
                rtype = rtype.strip().strip('"')

                if rtype != "5":
                    continue

                value_oid = ".1.3.6.1.2.1.99.1.1.1.4." + idx
                value_res = ctx.run(
                    ["snmpget", "-v2c", "-c", community, "-Oqv", host, value_oid],
                    mutates=False,
                )
                if value_res.rc != 0 or value_res.stdout == "":
                    continue
                reading = value_res.stdout.strip().strip('"')

                if _is_int(reading) and int(reading) == 1:
                    item_name = names.get(oid, "")
                    if item_name == "":
                        item_name = idx
                    discovery.append({
                        "item": item_name,
                        "params": {"power_off_criticality": params.get("power_off_criticality", 1)},
                        "metrics": [],
                    })

        return {
            "changed": False,
            "msg": "discovered %d power presence sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    value_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.99.1.1.1.4"],
        mutates=False,
    )
    if value_res.rc != 0 or value_res.stdout == "":
        return {
            "changed": False,
            "msg": "no entity sensor data on host " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    names = {}
    names_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.47.1.1.1.1.7"],
        mutates=False,
    )
    if names_res.rc == 0 and names_res.stdout != "":
        for line in names_res.stdout.splitlines():
            sp = line.find(" ")
            if sp > 0:
                oid = line[:sp]
                val = line[sp + 1:]
                names[oid] = val.strip('"')

    matched_item = None
    matched_idx = None
    matched_reading = None
    for line in value_res.stdout.splitlines():
        sp = line.find(" ")
        if sp <= 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip().strip('"')
        idx = oid[len(".1.3.6.1.2.1.99.1.1.1.4") + 1:]
        if idx == "":
            continue

        type_oid = ".1.3.6.1.2.1.99.1.1.1.1." + idx
        type_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, type_oid],
            mutates=False,
        )
        if type_res.rc != 0 or type_res.stdout == "":
            continue
        t = type_res.stdout.strip()
        type_parts = t.split(":")
        rtype = ""
        if len(type_parts) > 1:
            rtype = type_parts[1].strip().strip('"')
        else:
            rtype = t.strip().strip('"')

        if rtype != "5":
            continue

        candidate_name = names.get(oid, idx)
        if candidate_name == item or idx == item:
            matched_item = candidate_name
            matched_idx = idx
            matched_reading = val
            break

    if matched_item == None:
        return {
            "changed": False,
            "msg": "no power presence sensor found for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reading = matched_reading.strip()
    if not _is_int(reading):
        return {
            "changed": False,
            "msg": "could not parse reading for power presence sensor " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reading_int = int(reading)
    power_off_criticality = params.get("power_off_criticality", 1)

    if reading_int == 1:
        return {
            "changed": False,
            "msg": "Power " + item + " Powered on",
            "data": {"state": "OK", "metrics": {}, "details": "Powered on"},
        }

    state = "CRIT" if power_off_criticality == 2 else "WARN"
    return {
        "changed": False,
        "msg": "Power " + item + " Powered off",
        "data": {"state": state, "metrics": {}, "details": "Powered off"},
    }