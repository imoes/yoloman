def _snmpget_oid(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if not val:
        return None
    return val

def _akcp_exp_present(ctx, params):
    sys_oid = _snmpget_oid(ctx, params, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None:
        return False
    if not sys_oid.startswith(".1.3.6.1.4.1.3854.1"):
        return False
    probe = _snmpget_oid(ctx, params, ".1.3.6.1.4.1.3854.2")
    if probe == None:
        return False
    return True

def _walk_temp_table(ctx, params):
    base = ".1.3.6.1.4.1.3854.2.3.2.1"
    cols = ["2", "4", "5", "6", "9", "10", "11", "12", "19", "8"]
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    by_index = {}
    for ci, col in enumerate(cols):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + col],
            mutates=False,
        )
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp].strip()
            val = line[sp + 1:].strip()
            suffix = oid[len(base) + 1:]
            idx_part = suffix.rsplit(".", 1)
            if len(idx_part) < 2:
                continue
            index = idx_part[1]
            if index not in by_index:
                by_index[index] = ["", "", "", "", "", "", "", "", "", ""]
            by_index[index][ci] = val
    rows = []
    for index in sorted(by_index.keys()):
        rows.append(by_index[index])
    return rows

def main(ctx, params):
    if params.get("_discover"):
        if not _akcp_exp_present(ctx, params):
            return {"changed": False, "msg": "no AKCP EXP device found", "data": {"discovery": []}}
        rows = _walk_temp_table(ctx, params)
        out = []
        for line in rows:
            if len(line) < 10:
                continue
            if line[-1] == "1":
                out.append({
                    "item": line[0],
                    "params": {"levels": (32.0, 35.0)},
                    "metrics": ["temperature"],
                })
        return {"changed": False, "msg": "discovered %d sensors" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    if not _akcp_exp_present(ctx, params):
        return {"changed": False, "msg": "no AKCP EXP device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    rows = _walk_temp_table(ctx, params)
    target = None
    for line in rows:
        if len(line) >= 10 and line[0] == item:
            target = line
            break
    if target == None:
        return {"changed": False, "msg": "no such sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    (description, degree, unit, status, low_crit, low_warn, high_warn, high_crit, degreeraw, online) = target

    if online != "1":
        return {"changed": False, "msg": "sensor is offline", "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    if status in ["1", "7"]:
        akcp_states = {
            "1": (2, "no status"),
            "7": (2, "sensor error"),
        }
        if status in akcp_states:
            s, sn = akcp_states[status]
            st_map = {0: "OK", 1: "WARN", 2: "CRIT"}
            return {"changed": False, "msg": "State: " + sn, "data": {"state": st_map[s], "metrics": {}, "details": ""}}

    levels = params.get("levels", (32.0, 35.0))
    warn = levels[0] if type(levels) == "list" or type(levels) == "tuple" else 32.0
    crit = levels[1] if type(levels) == "list" or type(levels) == "tuple" else 35.0

    if unit.isdigit():
        unit_normalised = "f" if unit == "0" else "c"
        low_c, low_w, high_w, high_c = float(low_crit), float(low_warn), float(high_warn), float(high_crit)
    else:
        unit_normalised = unit.lower()
        if int(high_crit) > 100:
            low_c = float(low_crit) / 10.0
            low_w = float(low_warn) / 10.0
            high_w = float(high_warn) / 10.0
            high_c = float(high_crit) / 10.0
        else:
            low_c = float(low_crit)
            low_w = float(low_warn)
            high_w = float(high_warn)
            high_c = float(high_crit)

    if degreeraw and degreeraw != "0":
        temperature = float(degreeraw) / 10.0
    elif not degree:
        return {"changed": False, "msg": "Temperature information not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        temperature = float(degree)

    state = "OK"
    if temperature >= crit or temperature <= low_c:
        state = "CRIT"
    elif temperature >= warn or temperature <= low_w:
        state = "WARN"

    dev_levels = [high_w, high_c]
    dev_levels_lower = [low_w, low_c]
    dev_state = "OK"
    if temperature >= dev_levels[1]:
        dev_state = "CRIT"
    elif temperature >= dev_levels[0]:
        dev_state = "WARN"
    if temperature <= dev_levels_lower[0]:
        dev_state = "WARN"
    if temperature <= dev_levels_lower[1]:
        dev_state = "CRIT"

    final_state = state
    if dev_state == "CRIT" or state == "CRIT":
        final_state = "CRIT"
    elif dev_state == "WARN" or state == "WARN":
        final_state = "WARN"
    else:
        final_state = "OK"

    details = "Temperature: %f %s, Levels: %f-%f / %f-%f" % (
        temperature, unit_normalised, low_c, low_w, high_w, high_c
    )
    return {"changed": False, "msg": "Temperature: %f %s" % (temperature, unit_normalised), "data": {"state": final_state, "metrics": {"temperature": temperature}, "details": details}}