def _probe_oid(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        model = _probe_oid(ctx, community, host, ".1.3.6.1.2.1.47.1.1.1.1.2.1")
        fw = _probe_oid(ctx, community, host, ".1.3.6.1.4.1.1588.2.1.1.1.1.6.0")
        ssn = _probe_oid(ctx, community, host, ".1.3.6.1.4.1.1588.2.1.1.1.1.10.0")
        wwn_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.3.94.1.6.1.1"], mutates=False)
        wwn = ""
        if wwn_res.rc == 0:
            raw = wwn_res.stdout.strip()
            wwn = ":".join(["%X" % ord(tok) for tok in raw.split(" ")[:8]])
        data = "".join([model, ssn, fw, wwn])
        if data != "----":
            discovery = [{"item": "", "params": {}, "metrics": []}]
        else:
            discovery = []
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    model = _probe_oid(ctx, community, host, ".1.3.6.1.2.1.47.1.1.1.1.2.1")
    ssn = _probe_oid(ctx, community, host, ".1.3.6.1.4.1.1588.2.1.1.1.1.10.0")
    fw = _probe_oid(ctx, community, host, ".1.3.6.1.4.1.1588.2.1.1.1.1.6.0")
    wwn_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.3.94.1.6.1.1"], mutates=False)
    wwn = ""
    if wwn_res.rc == 0:
        raw = wwn_res.stdout.strip()
        wwn = ":".join(["%X" % ord(tok) for tok in raw.split(" ")[:8]])

    data = "".join([model, ssn, fw, wwn])
    if data != "----":
        infotext = "Model: %s, SSN: %s, Firmware Version: %s, WWN: %s" % (model, ssn, fw, wwn)
        return {"changed": False, "msg": infotext,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "no information found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}