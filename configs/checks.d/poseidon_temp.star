def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.21796.3.3.3.1"
    oids = ["2", "4", "5"]

    if params.get("_discover"):
        det = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if det.rc != 0:
            return {"changed": False, "msg": "Poseidon device not detected (snmpget failed)",
                    "data": {"discovery": []}}
        oid = det.stdout.strip()
        if not oid.startswith(".1.3.6.1.4.1.21796.3"):
            return {"changed": False, "msg": "Not a Poseidon device", "data": {"discovery": []}}

        col_data = {}
        for idx in range(len(oids)):
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + oids[idx]], mutates=False)
            if res.rc != 0:
                continue
            for line in res.stdout.splitlines():
                sp = line.find(" ")
                if sp < 0:
                    continue
                line_oid = line[:sp]
                line_val = line[sp + 1:]
                index = line_oid[len(base) + 1:]
                if index not in col_data:
                    col_data[index] = [None, None, None]
                col_data[index][idx] = line_val

        discovery = []
        for index in col_data:
            name = col_data[index][0]
            if name == None:
                continue
            discovery.append({"item": name, "params": {"levels": (None, None)},
                              "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_index = None
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        line_oid = line[:sp]
        line_val = line[sp + 1:]
        if line_val == item:
            target_index = line_oid[len(base) + 1:]
            break

    if target_index == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    st = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".4." + target_index], mutates=False)
    tp = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".5." + target_index], mutates=False)

    sensor_states = {"0": "invalid", "1": "normal", "2": "alarmstate", "3": "alarm"}
    sensor_state_value = st.stdout.strip() if st.rc == 0 else ""
    sensor_state_txt = sensor_states.get(sensor_state_value) if sensor_state_value else None

    mk_status = "OK"
    if sensor_state_value != "1":
        mk_status = "CRIT"

    temp = None
    if tp.rc == 0:
        raw = tp.stdout.strip()
        cp = raw.find(": ")
        if cp >= 0:
            raw = raw[cp + 2:]
        if raw.startswith('"') and raw.endswith('"'):
            raw = raw[1:-1]
        cleaned = raw.replace("C", "").strip()
        temp = float(cleaned) if _is_number(cleaned) else None

    state = mk_status
    metrics = {}
    details = "Sensor %s, State %s" % (item, sensor_state_txt)
    if temp != None:
        warn = params.get("warn")
        crit = params.get("crit")
        if warn == None and crit == None:
            levels = params.get("levels")
            if levels != None and len(levels) >= 2:
                warn = levels[0]
                crit = levels[1]
        if warn != None and crit != None:
            if temp >= crit:
                state = "CRIT"
            elif temp >= warn:
                state = "WARN"
        metrics["temperature"] = temp
        details = details + ", Temp: %f C" % temp
    else:
        state = "UNKNOWN"
        details = "No data for Sensor %s found" % item

    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details}}


def _is_number(s):
    if s == None or s == "":
        return False
    return _is_number_inner(s, 0, False, False, False)


def _is_number_inner(s, i, seen_dot, seen_digit, seen_minus):
    if i == len(s):
        return seen_digit
    c = s[i]
    if c == "-":
        if i != 0 or seen_minus or seen_digit or seen_dot:
            return False
        return _is_number_inner(s, i + 1, seen_dot, seen_digit, True)
    if c == ".":
        if seen_dot:
            return False
        return _is_number_inner(s, i + 1, True, seen_digit, seen_minus)
    if c >= "0" and c <= "9":
        return _is_number_inner(s, i + 1, seen_dot, True, seen_minus)
    return False