def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                       params.get("host", "localhost"), ".1.3.6.1.4.1.9694.1.5.5.1.2.0"],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no arbor peakflow tms found",
                    "data": {"discovery": []}}
        res2 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                        params.get("host", "localhost"), ".1.3.6.1.4.1.9694.1.5.5.2.1.0"],
                       mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "no arbor peakflow tms found",
                    "data": {"discovery": []}}
        device = res.stdout.strip()
        mitigation = res2.stdout.strip()
        section = {"Device": device, "Mitigation": mitigation}
        out = []
        for name in section:
            out.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), ".1.3.6.1.4.1.9694.1.5.5.1.2.0"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no arbor peakflow tms found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res2 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                    params.get("host", "localhost"), ".1.3.6.1.4.1.9694.1.5.5.2.1.0"],
                   mutates=False)
    if res2.rc != 0:
        return {"changed": False, "msg": "no arbor peakflow tms found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = {"Device": res.stdout.strip(), "Mitigation": res2.stdout.strip()}
    summary = section.get(item)
    if summary == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": {}, "details": ""}}