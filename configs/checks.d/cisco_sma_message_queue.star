def _to_float(s, default):
    if s == None or s == "":
        return default
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body.replace(".", "", 1).isdigit():
        return float(s)
    return default

def _to_int(s, default):
    if s == None or s == "":
        return default
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body.isdigit():
        return int(s)
    return default

def _warn_crit(params, key, default_warn, default_crit):
    lvls = params.get(key)
    if lvls != None and type(lvls) == "dict":
        w = lvls.get("warn", default_warn)
        c = lvls.get("crit", default_crit)
    else:
        w = default_warn
        c = default_crit
    return w, c

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.15497.1.1.1.4"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no cisco_sma on host",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"warn": 80.0, "crit": 90.0},
                     "metrics": ["cisco_sma_queue_utilization",
                                 "cisco_sma_queue_length",
                                 "cisco_sma_queue_oldest_message_age"]},
                ]}}

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.15497.1.1.1"
    oids = ["4", "5", "11", "14"]
    values = {}
    ok = True
    for label in oids:
        oid = base + "." + label
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc != 0:
            ok = False
            break
        values[label] = res.stdout.strip()

    if not ok:
        return {"changed": False, "msg": "no cisco_sma data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    utilization = _to_float(values.get("4"), 0.0)
    status_code = _to_int(values.get("5"), 0)
    length = _to_int(values.get("11"), 0)
    oldest = _to_float(values.get("14"), 0.0)

    ms_map = {1: "OK", 2: "WARN", 3: "CRIT"}
    status_map = {1: "Memory available", 2: "Memory shortage", 3: "Memory full"}
    avail_state = ms_map.get(status_code, "UNKNOWN")
    avail_msg = status_map.get(status_code, "Memory state unknown")

    w_util, c_util = _warn_crit(params, "levels_queue_utilization", 80.0, 90.0)
    if utilization >= c_util:
        util_state = "CRIT"
    elif utilization >= w_util:
        util_state = "WARN"
    else:
        util_state = "OK"

    w_len, c_len = _warn_crit(params, "levels_queue_length", 500, 1000)
    if length >= c_len:
        len_state = "CRIT"
    elif length >= w_len:
        len_state = "WARN"
    else:
        len_state = "OK"

    age_cfg = params.get("levels_oldest_message_age")
    if age_cfg != None and type(age_cfg) == "dict":
        w_age = age_cfg.get("warn", 0)
        c_age = age_cfg.get("crit", 0)
    else:
        w_age = 0
        c_age = 0
    if c_age > 0:
        if oldest >= c_age:
            age_state = "CRIT"
        elif oldest >= w_age:
            age_state = "WARN"
        else:
            age_state = "OK"
    else:
        age_state = "OK"

    states = [avail_state, util_state, len_state, age_state]
    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"

    msg = avail_msg + " - Utilization: %f%%, Total messages: %d, Oldest message age: %fs" % (utilization, length, oldest)

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"cisco_sma_queue_utilization": utilization,
                                 "cisco_sma_queue_length": length,
                                 "cisco_sma_queue_oldest_message_age": oldest},
                     "details": msg}}