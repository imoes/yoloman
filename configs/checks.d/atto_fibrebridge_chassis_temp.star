def main(ctx, params):
    if params.get("_discover"):
        sys_oid = _get_scalar(ctx, params, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == None or not sys_oid.startswith(".1.3.6.1.4.1.4547"):
            return {"changed": False, "msg": "no Atto Fibrebridge device found",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.4.1.4547.2.3.2"
        min_t = _get_scalar(ctx, params, base + ".4")
        max_t = _get_scalar(ctx, params, base + ".5")
        chassis_t = _get_scalar(ctx, params, base + ".8")
        throughput = _get_scalar(ctx, params, base + ".11")
        if min_t == None or max_t == None or chassis_t == None:
            return {"changed": False, "msg": "incomplete Atto Fibrebridge data",
                    "data": {"discovery": []}}
        warn = params.get("warn", 70)
        crit = params.get("crit", 80)
        return {"changed": False, "msg": "discovered Atto Fibrebridge chassis",
                "data": {"discovery": [
                    {"item": "Chassis", "params": {"warn": warn, "crit": crit},
                     "metrics": ["temp"]},
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    item = params.get("item", "")
    if item == "Chassis" or item == "":
        base = ".1.3.6.1.4.1.4547.2.3.2"
        min_t = _get_scalar(ctx, params, base + ".4")
        max_t = _get_scalar(ctx, params, base + ".5")
        chassis_t = _get_scalar(ctx, params, base + ".8")
        if min_t == None or max_t == None or chassis_t == None:
            return {"changed": False,
                    "msg": "no Atto Fibrebridge chassis data available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        reading = int(chassis_t)
        warn = params.get("warn", 70)
        crit = params.get("crit", 80)
        if reading >= crit:
            state = "CRIT"
        elif reading >= warn:
            state = "WARN"
        else:
            state = "OK"
        return {"changed": False,
                "msg": "Chassis temperature: %d C" % reading,
                "data": {"state": state, "metrics": {"temp": reading},
                         "details": "min_operating=%s max_operating=%s" % (min_t, max_t)}}

    return {"changed": False, "msg": "unknown item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def _get_scalar(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                  mutates=False)
    if res.rc != 0:
        return None
    v = res.stdout.strip()
    return v if v != "" else None