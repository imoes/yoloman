def main(ctx, params):
    if params.get("_discover"):
        exports = []
        if ctx.file_exists("/proc/fs/nfsd/exports"):
            content = ctx.file_read("/proc/fs/nfsd/exports")
            for line in content.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[0].startswith("/"):
                    exports.append({"item": parts[0], "params": {}, "metrics": []})
        else:
            res = ctx.run(["cat", "/proc/mounts"], mutates=False)
            for line in res.stdout.splitlines():
                fields = line.split()
                if len(fields) >= 3 and fields[2] == "nfsd":
                    exports_path = fields[1] + "/exports"
                    if ctx.file_exists(exports_path):
                        content = ctx.file_read(exports_path)
                        for exp_line in content.splitlines():
                            exp_parts = exp_line.split()
                            if len(exp_parts) >= 2 and exp_parts[0].startswith("/"):
                                path = exp_parts[0]
                                already = False
                                for e in exports:
                                    if e["item"] == path:
                                        already = True
                                        break
                                if not already:
                                    exports.append({"item": path, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d NFS exports" % len(exports),
                "data": {"discovery": exports}}

    item = params.get("item", "")
    found = False
    if ctx.file_exists("/proc/fs/nfsd/exports"):
        content = ctx.file_read("/proc/fs/nfsd/exports")
        for line in content.splitlines():
            parts = line.split()
            if len(parts) >= 1 and parts[0] == item:
                found = True
                break
    else:
        res = ctx.run(["cat", "/proc/mounts"], mutates=False)
        for line in res.stdout.splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[2] == "nfsd":
                exports_path = fields[1] + "/exports"
                if ctx.file_exists(exports_path):
                    content = ctx.file_read(exports_path)
                    for line in content.splitlines():
                        parts = line.split()
                        if len(parts) >= 1 and parts[0] == item:
                            found = True
                            break
                if found:
                    break
    if not found:
        return {"changed": False, "msg": "export not found in export list",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "export is active",
            "data": {"state": "OK", "metrics": {}, "details": ""}}