def _round1(v):
    return (v * 10 + 0.5) / 10 if v >= 0 else (v * 10 - 0.5) / 10

def main(ctx, params):
    if params.get("_discover"):
        sysid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Ovqn", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysid.rc != 0 or not sysid.stdout:
            return {"changed": False, "msg": "bintec device not found (no sysObjectID)", "data": {"discovery": []}}
        # sysObjectID must be under the bintec enterprise OID .1.3.6.1.4.1.272
        if not sysid.stdout.startswith(".1.3.6.1.4.1.272"):
            return {"changed": False, "msg": "bintec device not found (sysoid not bintec)", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": ["cpu_util", "streams"]}]}}

    base = ".1.3.6.1.4.1.272.4.17.4.1.1"
    user = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".15.1.0"], mutates=False)
    system = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".16.1.0"], mutates=False)
    streams = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".17.1.0"], mutates=False)
    if user.rc != 0 or system.rc != 0 or streams.rc != 0:
        return {"changed": False, "msg": "bintec CPU data not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    u = float(user.stdout) if user.stdout else 0.0
    s = float(system.stdout) if system.stdout else 0.0
    st = float(streams.stdout) if streams.stdout else 0.0
    util = u + s + st
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    levels = params.get("levels", (warn, crit))
    if type(levels) == "list" and len(levels) >= 2:
        cw, cc = float(levels[0]), float(levels[1])
    else:
        cw, cc = float(warn), float(crit)
    # CPU utilization: upper levels -> WARN if >= warn, CRIT if >= crit
    state = "CRIT" if util >= cc else ("WARN" if util >= cw else "OK")
    summary = "user: %f%%, system: %f%%, streams: %f%%, util: %f%%" % (_round1(u), _round1(s), _round1(st), _round1(util))
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {"cpu_util": util, "streams": st}, "details": ""}}