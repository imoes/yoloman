def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.110901.1.4.2.0", ".1.3.6.1.4.1.110901.1.4.4.0", ".1.3.6.1.4.1.110901.1.4.5.0"
        ], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            if ".1.3.6.1.4.1.110901.1.4.2.0" in line:
                val = line.rsplit(" = INTEGER: ", 1)[-1].strip()
                if val.isdigit():
                    out.append({"item": "", "params": {}, "metrics": ["managed_object_count", "storage_used"]})
                    break
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # CHECK mode: fetch required OIDs
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.110901.1.4.2.0", ".1.3.6.1.4.1.110901.1.4.4.0", ".1.3.6.1.4.1.110901.1.4.5.0"
    ], mutates=False)

    object_count = 0
    remaining_size = 0
    total_size = 0
    found = False
    for line in res.stdout.splitlines():
        if ".1.3.6.1.4.1.110901.1.4.2.0" in line:
            val = line.rsplit(" = INTEGER: ", 1)[-1].strip()
            if val.isdigit():
                object_count = int(val)
                found = True
        elif ".1.3.6.1.4.1.110901.1.4.4.0" in line:
            val = line.rsplit(" = INTEGER: ", 1)[-1].strip()
            if val.isdigit():
                remaining_size = int(val)
        elif ".1.3.6.1.4.1.110901.1.4.5.0" in line:
            val = line.rsplit(" = INTEGER: ", 1)[-1].strip()
            if val.isdigit():
                total_size = int(val)

    if not found:
        return {"changed": False, "msg": "no DIVA managed objects data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    GB = 1073741824
    storage_used = (total_size - remaining_size) * GB
    infotext = "managed objects: %d, remaining size: %d GB of %d GB" % (object_count, remaining_size, total_size)

    return {"changed": False, "msg": infotext,
            "data": {"state": "OK", "metrics": {
                "managed_object_count": object_count,
                "storage_used": storage_used
            }, "details": ""}}
