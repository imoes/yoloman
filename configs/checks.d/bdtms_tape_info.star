def main(ctx, params):
    if params.get("_discover"):
        sysoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", "-OQ", params.get("host", "localhost"),
             ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid_res.rc != 0 or not sysoid_res.stdout:
            return {"changed": False, "msg": "not a BDT tape library",
                    "data": {"discovery": []}}
        sysoid = sysoid_res.stdout.strip().strip('"')
        if not sysoid.endswith(".1.3.6.1.4.1.20884.77.83.1"):
            return {"changed": False, "msg": "not a BDT tape library",
                    "data": {"discovery": []}}
        row_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", "-OQ", params.get("host", "localhost"),
             ".1.3.6.1.4.1.20884.1.1",
             ".1.3.6.1.4.1.20884.1.2",
             ".1.3.6.1.4.1.20884.1.3",
             ".1.3.6.1.4.1.20884.1.4"],
            mutates=False,
        )
        if row_res.rc != 0:
            return {"changed": False, "msg": "not a BDT tape library",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}
    row_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", "-OQ", params.get("host", "localhost"),
         ".1.3.6.1.4.1.20884.1.1",
         ".1.3.6.1.4.1.20884.1.2",
         ".1.3.6.1.4.1.20884.1.3",
         ".1.3.6.1.4.1.20884.1.4"],
        mutates=False,
    )
    if row_res.rc != 0:
        return {"changed": False, "msg": "not a BDT tape library",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vals = [v.strip().strip('"') for v in row_res.stdout.splitlines() if v.strip()]
    if len(vals) < 4:
        return {"changed": False, "msg": "incomplete tape info response",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "expected 4 values, got %d" % len(vals)}}
    labels = ["Vendor", "Product ID", "Serial Number", "Software Revision"]
    out = []
    for name, value in zip(labels, vals):
        out.append("%s: %s" % (name, value))
    return {"changed": False, "msg": ", ".join(out),
            "data": {"state": "OK", "metrics": {}, "details": "\n".join(out)}}