def main(ctx, params):
    if params.get("_discover"):
        # Probe for MongoDB serverStatus data on-host.
        res = ctx.run(
            ["mongo", "--quiet", "--eval",
             "JSON.stringify(db.serverStatus().opcounters)"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "mongo binary not available or errored",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "no opcounters data",
                    "data": {"discovery": []}}

        ops = json.decode(res.stdout)
        if ops == None or len(ops) == 0:
            return {"changed": False, "msg": "no opcounters counters",
                    "data": {"discovery": []}}

        metrics = ["%s_ops" % k for k in ops]
        discovery = [{"item": "Operations", "params": {},
                      "metrics": metrics, "service_labels": {}}]

        # Replica-set counters live under opcountersRepl.
        res2 = ctx.run(
            ["mongo", "--quiet", "--eval",
             "JSON.stringify(db.serverStatus().opcountersRepl)"],
            mutates=False,
        )
        if res2.rc == 0 and res2.stdout:
            repl = json.decode(res2.stdout)
            if not (repl == None) and len(repl) > 0:
                repl_metrics = ["%s_ops" % k for k in repl]
                discovery.append({"item": "Replica Operations", "params": {},
                                  "metrics": repl_metrics,
                                  "service_labels": {}})

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    item_map = {"Operations": "opcounters", "Replica Operations": "opcountersRepl"}
    field = item_map.get(item, None)
    if field == None:
        return {"changed": False,
                "msg": "unknown item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["mongo", "--quiet", "--eval",
         "JSON.stringify(db.serverStatus().%s)" % field],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False,
                "msg": "mongo query failed for %s" % field,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not res.stdout:
        return {"changed": False,
                "msg": "no data returned for %s" % field,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)
    if data == None or len(data) == 0:
        return {"changed": False,
                "msg": "no counters in section %s" % field,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_lines = []
    for what, value in data.items():
        v = value if type(value) == "int" or type(value) == "float" else 0
        metrics["%s_ops" % what] = v
        details_lines.append("%s: %d" % (what.title(), v))

    msg = "%s counters: %s" % (item, ", ".join(details_lines))
    return {"changed": False,
            "msg": msg,
            "data": {"state": "OK", "metrics": metrics, "details": msg}}