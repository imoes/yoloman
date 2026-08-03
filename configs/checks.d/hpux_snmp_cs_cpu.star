# Translated Checkmk check: hpux_snmp_cs_cpu (CPU utilization via SNMP)

def main(ctx, params):
    base = ".1.3.6.1.4.1.11.2.3.1.1"
    cols = {
        "13.0": "user",
        "14.0": "system",
        "15.0": "idle",
        "16.0": "nice",
    }
    # Detection: walk the sysUpTime OID to confirm SNMP agent is reachable
    det = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), base + ".1.0"], mutates=False)
    if det.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no SNMP agent found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "SNMP agent not reachable (rc=%d)" % det.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        return {"changed": False, "msg": "discovered CPU utilization",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["user", "system", "idle", "nice"]}]}}

    item = params.get("item", "")
    vals = {}
    for oid, what in cols.items():
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oid],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read " + what + " CPU: rc=%d" % res.rc,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        s = res.stdout.strip()
        vals[oid] = int(s) if s.isdigit() else 0

    total = vals["13.0"] + vals["14.0"] + vals["15.0"] + vals["16.0"]
    if total == 0:
        return {"changed": False, "msg": "No counter counted. Time has ceased to flow.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    infos = []
    labels = [("user", vals["13.0"]), ("system", vals["14.0"]),
              ("idle", vals["15.0"]), ("nice", vals["16.0"])]
    for what, v in labels:
        perc = v / float(total) * 100.0
        metrics[what] = perc
        infos.append("%s: %f%%" % (what, perc))

    return {"changed": False, "msg": ", ".join(infos),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}