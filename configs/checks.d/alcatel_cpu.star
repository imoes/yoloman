def main(ctx, params):
    if params.get("_discover"):
        sys_oid = _get_sys_oid(ctx, params)
        if sys_oid == None:
            return {"changed": False, "msg": "Alcatel device not detected",
                    "data": {"discovery": []}}
        if _is_aos7(sys_oid):
            oid = ".1.3.6.1.4.1.6486.801.1.2.1.16.1.1.1.1.1.15"
        else:
            oid = ".1.3.6.1.4.1.6486.800.1.2.1.16.1.1.1.13"
        res = ctx.run(["snmpget", "-v2c", "-c",
                       params.get("community", "public"), "-Oqv",
                       params.get("host", "localhost"), oid], mutates=False)
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no CPU utilization data found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"warn": 90.0, "crit": 95.0},
                     "metrics": ["util"]}]}}

    oid = _resolve_cpu_oid(ctx, params)
    if oid == None:
        return {"changed": False, "msg": "Alcatel device not detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["snmpget", "-v2c", "-c",
                   params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), oid], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False,
                "msg": "no CPU utilization data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    pct = int(raw) if raw.isdigit() else _to_int(raw)
    if pct == None:
        return {"changed": False,
                "msg": "could not parse CPU utilization: %s" % raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    warn = params.get("warn", 90.0)
    crit = params.get("crit", 95.0)
    state = "CRIT" if pct >= crit else ("WARN" if pct >= warn else "OK")
    return {"changed": False,
            "msg": "CPU utilization Total: %s%%" % pct,
            "data": {"state": state,
                     "metrics": {"util": pct},
                     "details": ""}}


def _get_sys_oid(ctx, params):
    res = ctx.run(["snmpget", "-v2c", "-c",
                   params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                  mutates=False)
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val


def _is_aos7(sys_oid):
    return sys_oid.startswith(".1.3.6.1.4.1.6486.801")


def _resolve_cpu_oid(ctx, params):
    sys_oid = _get_sys_oid(ctx, params)
    if sys_oid == None:
        return None
    if _is_aos7(sys_oid):
        return ".1.3.6.1.4.1.6486.801.1.2.1.16.1.1.1.1.1.15"
    return ".1.3.6.1.4.1.6486.800.1.2.1.16.1.1.1.13"


def _to_int(s):
    digits = ""
    for ch in s:
        if ch.isdigit():
            digits = digits + ch
        else:
            break
    return int(digits) if digits else None