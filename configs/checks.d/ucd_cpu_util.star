def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = "1.3.6.1.4.1.2021.11"
        probe = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "no UCD-SNMP-MIB available (SNMP agent absent)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["cpu_util", "read_blocks", "write_blocks"]}]}}
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = "1.3.6.1.4.1.2021.11"
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base], mutates=False)
    if walk.rc != 0 or not walk.stdout:
        return {"changed": False, "msg": "no UCD-SNMP-MIB data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vals = {}
    idx = 0
    lines = walk.stdout.splitlines()
    nlines = len(lines)
    while idx < nlines:
        line = lines[idx]
        idx = idx + 1
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp+1:]
        suffix = oid[len(base)+1:] if oid.startswith(base + ".") else oid[len(base):]
        vals[suffix] = val
    req = ["50", "51", "52", "53"]
    ok = True
    i = 0
    while i < len(req):
        if req[i] not in vals:
            ok = False
        i = i + 1
    if not ok:
        return {"changed": False, "msg": "incomplete UCD-SNMP-MIB cpu counters",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    def to_int(s):
        return int(s) if s.lstrip("-").isdigit() else 0
    user = to_int(vals.get("50", ""))
    nice = to_int(vals.get("51", ""))
    sysc = to_int(vals.get("52", ""))
    idle = to_int(vals.get("53", ""))
    wait = to_int(vals.get("54", ""))
    intr = to_int(vals.get("56", ""))
    softirq = to_int(vals.get("61", ""))
    total = user + nice + sysc + idle + wait + intr + softirq
    util = ((total - idle) * 100.0 / total) if total > 0 else 0
    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")
    io_sent = to_int(vals.get("57", ""))
    io_recv = to_int(vals.get("58", ""))
    metrics = {"cpu_util": util, "read_blocks": io_recv, "write_blocks": io_sent}
    return {"changed": False,
            "msg": "CPU utilization %f%%" % util,
            "data": {"state": state, "metrics": metrics, "details": ""}}