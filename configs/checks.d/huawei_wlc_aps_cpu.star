def _pow_int(b, e):
    if e < 0:
        return 1.0
    result = 1
    for _ in range(e):
        result = result * b
    return float(result)

def _radio_state(v):
    m = {
        "1": ("up", 0),
        "2": ("down", 2),
    }
    return m.get(v, ("not available", 3))

def _ap_state(v):
    m = {
        "1": ("Idle", 2),
        "2": ("Auto find", 1),
        "3": ("Type not match", 2),
        "4": ("Fault", 2),
        "5": ("Config", 2),
        "6": ("Config failed", 2),
        "7": ("Download", 1),
        "8": ("Normal", 0),
        "9": ("Committing", 2),
        "10": ("Commit failed", 2),
        "11": ("Standy", 1),
        "12": ("Version mismatch", 2),
        "13": ("Name conflicted", 2),
        "14": ("Invalid", 2),
        "15": ("Country code mismatch", 2),
    }
    return m.get(v, ("not available", 3))

def _strip_type(s):
    i = s.find(": ")
    if i >= 0:
        return s[i + 2:]
    return s.strip()

def _strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s

def _parse_float(s):
    s2 = s.strip()
    if s2 == "" or s2 == None:
        return None
    neg = False
    body = s2
    if body[0:1] == "-":
        neg = True
        body = body[1:]
    if body == "" or body.count(".") > 1:
        return None
    ok = True
    seen_dot = False
    if body == ".":
        return None
    dot_pos = body.find(".")
    int_part = body[0:dot_pos] if dot_pos >= 0 else body
    frac_part = body[dot_pos + 1:] if dot_pos >= 0 else ""
    for ch in int_part:
        if ch < "0" or ch > "9":
            ok = False
            break
    if not ok:
        return None
    for ch in frac_part:
        if ch < "0" or ch > "9":
            ok = False
            break
    if not ok:
        return None
    if int_part == "" and frac_part == "":
        return None
    val = 0.0
    for ch in int_part:
        val = val * 10.0 + (ord(ch) - 48)
    fval = 0.0
    for ch in frac_part:
        fval = fval * 10.0 + (ord(ch) - 48)
    fval = fval / _pow_int(10, len(frac_part))
    val = val + fval
    if neg:
        val = -val
    return val

def _parse_int(s):
    s2 = s.strip()
    if s2 == "" or s2 == None:
        return None
    neg = False
    body = s2
    if body[0:1] == "-":
        neg = True
        body = body[1:]
    val = 0
    for ch in body:
        if ch < "0" or ch > "9":
            return None
        val = val * 10 + (ord(ch) - 48)
    if neg:
        val = -val
    return val

def _to_float_or_default(s, default):
    v = _parse_float(s)
    if v == None:
        return default
    return v

def _to_int_or_default(s, default):
    v = _parse_int(s)
    if v == None:
        return default
    return v

def _walk(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, oid], mutates=False)
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        rows.append((parts[0], parts[1]))
    return rows

def _get(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return _strip_quotes(_strip_type(res.stdout.strip()))

def _sys_descr(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.1.0"], mutates=False)
    if res.rc != 0:
        return ""
    return _strip_type(res.stdout.strip())

def _walk_to_map(rows, base_col):
    m = {}
    for oid, val in rows:
        suffix = oid[len(base_col):]
        if suffix.startswith("."):
            idx = suffix[1:]
        else:
            idx = suffix
        if idx == "":
            idx = "0"
        m[idx] = val
    return m

def _fetch_aps(ctx, host, community):
    base1 = "1.3.6.1.4.1.2011.6.139.13.3.3.1"
    base2 = "1.3.6.1.4.1.2011.6.139.16.1.2.1"

    col_status = base1 + ".6"
    col_mem = base1 + ".40"
    col_cpu = base1 + ".41"
    col_temp = base1 + ".43"
    col_con_users = base1 + ".44"

    col_ap_id = base2 + ".3"
    col_r2_state = base2 + ".6"
    col_r2_chuse = base2 + ".25"
    col_r2_users = base2 + ".40"

    col_r5_state = base2 + ".6"
    col_r5_chuse = base2 + ".25"
    col_r5_users = base2 + ".40"

    ap_id_w = _walk(ctx, host, community, col_ap_id)
    if not ap_id_w:
        return {}

    status_w = _walk(ctx, host, community, col_status)
    mem_w = _walk(ctx, host, community, col_mem)
    cpu_w = _walk(ctx, host, community, col_cpu)
    temp_w = _walk(ctx, host, community, col_temp)
    con_users_w = _walk(ctx, host, community, col_con_users)

    r2_state_w = _walk(ctx, host, community, col_r2_state)
    r2_chuse_w = _walk(ctx, host, community, col_r2_chuse)
    r2_users_w = _walk(ctx, host, community, col_r2_users)

    r5_state_w = _walk(ctx, host, community, col_r5_state)
    r5_chuse_w = _walk(ctx, host, community, col_r5_chuse)
    r5_users_w = _walk(ctx, host, community, col_r5_users)

    status_m = _walk_to_map(status_w, col_status)
    mem_m = _walk_to_map(mem_w, col_mem)
    cpu_m = _walk_to_map(cpu_w, col_cpu)
    temp_m = _walk_to_map(temp_w, col_temp)
    con_users_m = _walk_to_map(con_users_w, col_con_users)

    ap_id_map = _walk_to_map(ap_id_w, col_ap_id)

    r2_state_m = _walk_to_map(r2_state_w, col_r2_state)
    r2_chuse_m = _walk_to_map(r2_chuse_w, col_r2_chuse)
    r2_users_m = _walk_to_map(r2_users_w, col_r2_users)
    r5_state_m = _walk_to_map(r5_state_w, col_r5_state)
    r5_chuse_m = _walk_to_map(r5_chuse_w, col_r5_chuse)
    r5_users_m = _walk_to_map(r5_users_w, col_r5_users)

    aps = {}
    for idx, name in ap_id_map.items():
        st = status_m.get(idx, "15")
        ap_st = _ap_state(st)
        mem_raw = mem_m.get(idx, "0")
        cpu_raw = cpu_m.get(idx, "0")
        temp_raw = temp_m.get(idx, "255")
        con_users_raw = con_users_m.get(idx, "0")

        mem = _to_float_or_default(mem_raw, 0.0)
        cpu = _to_float_or_default(cpu_raw, 0.0)
        con_users = _to_int_or_default(con_users_raw, 0)

        if temp_raw == "255" or temp_raw == "" or temp_raw == None:
            temp_value = "invalid"
        else:
            tv = _parse_float(temp_raw)
            if tv == None:
                temp_value = "invalid"
            else:
                temp_value = tv

        r2s = r2_state_m.get(idx, "1")
        r2c = r2_chuse_m.get(idx, "0")
        r2u = r2_users_m.get(idx, "0")
        r5s = r5_state_m.get(idx, "1")
        r5c = r5_chuse_m.get(idx, "0")
        r5u = r5_users_m.get(idx, "0")

        r2_state = _radio_state(r2s)
        r5_state = _radio_state(r5s)

        r2_chuse = _to_float_or_default(r2c, 0.0)
        r2_users = _to_int_or_default(r2u, 0)
        r5_chuse = _to_float_or_default(r5c, 0.0)
        r5_users = _to_int_or_default(r5u, 0)

        aps[name] = {
            "cmk_status": ap_st[1],
            "state_readable": ap_st[0],
            "mem_used_percent": mem,
            "cpu_percent": cpu,
            "temp": temp_value,
            "con_users": con_users,
            "24ghz": {
                "radio_cmk_state": r2_state[1],
                "radio_readable_state": r2_state[0],
                "ch_usage": r2_chuse,
                "users_online": r2_users,
            },
            "5ghz": {
                "radio_cmk_state": r5_state[1],
                "radio_readable_state": r5_state[0],
                "ch_usage": r5_chuse,
                "users_online": r5_users,
            },
        }
    return aps

def _state_name(n):
    names = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    return names.get(n, "UNKNOWN")

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        descr = _sys_descr(ctx, host, community)
        if descr == "" or descr.find("2011.2.240.17") < 0:
            return {"changed": False, "msg": "not a Huawei WLC",
                    "data": {"discovery": []}}

        aps = _fetch_aps(ctx, host, community)
        if not aps:
            return {"changed": False, "msg": "no APs found",
                    "data": {"discovery": []}}

        levels = params.get("levels", (80.0, 90.0))
        out = []
        for name in aps:
            out.append({"item": name,
                        "params": {"levels": levels},
                        "metrics": ["cpu_percent"]})
        return {"changed": False, "msg": "discovered %d APs" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    levels = params.get("levels", (80.0, 90.0))

    aps = _fetch_aps(ctx, host, community)

    if not aps:
        return {"changed": False,
                "msg": "no Huawei WLC AP data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item == "":
        names = list(aps.keys())
        if len(names) == 0:
            return {"changed": False,
                    "msg": "no APs found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        item = names[0]

    data = aps.get(item)
    if data == None:
        return {"changed": False,
                "msg": "AP %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu = data["cpu_percent"]
    state = 0
    warn, crit = levels
    if cpu >= crit:
        state = 2
    elif cpu >= warn:
        state = 1

    msg = "Usage: %f%%" % cpu
    return {"changed": False,
            "msg": msg,
            "data": {"state": _state_name(state),
                     "metrics": {"cpu_percent": cpu},
                     "details": ""}}