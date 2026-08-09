def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv", host,
            ".1.3.6.1.4.1.9551.1.1.1.0",
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "Alertmanager not reachable", "data": {"discovery": []}}
        out = []
        if params.get("summary_service", True):
            out.append({"item": "", "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.9551.1.1.1.0",
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Alertmanager not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = json.decode(res.stdout) if res.stdout else {}
    count = 0
    if type(section) == dict:
        for rules in section.values():
            if type(rules) == dict:
                count += len(rules)
    return {"changed": False, "msg": "Number of rules: %d" % count,
            "data": {"state": "OK", "metrics": {"num_rules": count}, "details": ""}}