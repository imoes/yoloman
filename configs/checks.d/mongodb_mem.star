def main(ctx, params):
    if params.get("_discover"):
        # Single-service check: discover one service if MongoDB is running.
        ps = ctx.run(["ps", "-eo", "comm="], mutates=False)
        has_mongo = False
        if ps.rc == 0:
            for line in ps.stdout.splitlines():
                if line.strip() == "mongod":
                    has_mongo = True
                    break
        if not has_mongo:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": [
                        "process_resident_size", "process_virtual_size", "process_mapped_size"
                    ]},
                ]}}

    # CHECK MODE
    ps = ctx.run(["ps", "-eo", "pmem,rss,vsz,comm="], mutates=False)
    found = False
    rss_kb = 0
    vsz_kb = 0
    if ps.rc == 0:
        for line in ps.stdout.splitlines():
            f = line.split()
            if len(f) >= 4 and f[-1] == "mongod":
                rss_str = f[1]
                vsz_str = f[2]
                rss_kb = int(rss_str) if rss_str.isdigit() else 0
                vsz_kb = int(vsz_str) if vsz_str.isdigit() else 0
                found = True
                break

    if not found:
        return {"changed": False,
                "msg": "no mongod process found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_lines = []

    resident_mb = rss_kb / 1024.0
    metrics["process_resident_size"] = resident_mb * 1024 * 1024
    details_lines.append("resident %f MB" % resident_mb)

    virtual_mb = vsz_kb / 1024.0
    metrics["process_virtual_size"] = virtual_mb * 1024 * 1024
    details_lines.append("virtual %f MB" % virtual_mb)

    msg = "resident %s, virtual %s" % (resident_mb, virtual_mb)
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": metrics,
                     "details": ", ".join(details_lines)}}