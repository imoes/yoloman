DETECT_PRAVAIL_SYSDESCR = [
    ".1.3.6.1.4.1.9694.1.1.0",
]

def _detect_pravail(ctx, params):
    for oid in DETECT_PRAVAIL_SYSDESCR:
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), oid],
            mutates=False,
        )
        if res.rc == 0:
            return True
        if res.rc != 2 and res.rc != 0:
            return False
    return False

def _fetch_drop_rate(ctx, params):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.9694.1.6.2.39.0"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "" or not out.strip():
        return None
    return int(out) if out.strip().isdigit() else None

def _check_levels(value, levels_upper, levels_lower, metric_name):
    wcrit, wwarn = None, None
    ccrit, cwarn = None, None
    if levels_upper != None:
        wcrit, wwarn = levels_upper[0], levels_upper[1]
    if levels_lower != None:
        ccrit, cwarn = levels_lower[0], levels_lower[1]
    state = "OK"
    if wcrit != None and wwarn != None:
        if value >= wcrit:
            state = "CRIT"
        elif value >= wwarn:
            state = "WARN"
    if ccrit != None and cwarn != None:
        if value <= ccrit:
            state = "CRIT"
        elif value <= cwarn:
            state = "WARN"
    return state

def main(ctx, params):
    if params.get("_discover"):
        if not _detect_pravail(ctx, params):
            return {"changed": False, "msg": "no Arbor Pravail detected",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "Overrun", "params": {},
                     "metrics": ["if_in_pkts"]}
                ]}}
    drop_rate = _fetch_drop_rate(ctx, params)
    if drop_rate == None:
        return {"changed": False, "msg": "no drop rate data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels_upper = params.get("levels", None)
    levels_lower = params.get("levels_lower", None)
    state = _check_levels(drop_rate, levels_upper, levels_lower, "if_in_pkts")
    msg = "%f pps" % float(drop_rate)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"if_in_pkts": drop_rate},
                     "details": ""}}