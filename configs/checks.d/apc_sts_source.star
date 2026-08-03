def main(ctx, params):
    base = ".1.3.6.1.4.1.705.2"
    col1 = base + ".3.5"
    col2 = base + ".4.5"

    if params.get("_discover"):
        # Probe for the real thing: SNMP sysObjectID must match APC STS.
        sysoid_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysoid_res.rc != 0 or not sysoid_res.stdout:
            return {"changed": False, "msg": "not an APC STS device", "data": {"discovery": [], "host_labels": {}}}

        if ".1.3.6.1.4.1.705.2.2" not in sysoid_res.stdout:
            return {"changed": False, "msg": "APC STS device not detected", "data": {"discovery": [], "host_labels": {}}}

        r1 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), col1], mutates=False)
        r2 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), col2], mutates=False)
        if r1.rc != 0 or r2.rc != 0 or not r1.stdout or not r2.stdout:
            return {"changed": False, "msg": "could not read APC STS source OIDs", "data": {"discovery": [], "host_labels": {}}}

        source1 = r1.stdout.strip()
        source2 = r2.stdout.strip()
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"source1": source1, "source2": source2}, "metrics": []}], "host_labels": {}}}

    # Check mode
    r1 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), col1], mutates=False)
    r2 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), col2], mutates=False)
    if r1.rc != 0 or r2.rc != 0 or not r1.stdout or not r2.stdout:
        return {"changed": False, "msg": "could not read APC STS source OIDs", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sources = {"source1": r1.stdout.strip(), "source2": r2.stdout.strip()}
    states = {"1": "in use", "2": "not used"}
    p_source1 = params.get("source1")
    p_source2 = params.get("source2")
    overall_state = "OK"
    parts = []
    for name, what in [("Source 1", "source1"), ("Source 2", "source2")]:
        what_state = "OK"
        s = sources[what]
        stxt = states.get(s, s)
        infotext = "%s: %s" % (name, stxt)
        if (what == "source1" and p_source1 != None and p_source1 != s) or (what == "source2" and p_source2 != None and p_source2 != s):
            what_state = "WARN"
            infotext += " (State has changed)"
        if what_state == "WARN" and overall_state == "OK":
            overall_state = "WARN"
        parts.append(infotext)

    return {"changed": False, "msg": ", ".join(parts), "data": {"state": overall_state, "metrics": {}, "details": ""}}