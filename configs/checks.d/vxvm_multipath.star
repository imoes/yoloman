def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["ls", "-1", "/sys/block/"], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            name = line.strip()
            if name != "":
                items.append({"item": name, "params": {}, "metrics": ["active_paths", "paths", "inactive_paths"]})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["bash", "-c", "echo ' vxvm_multipath data not available on this agent'"], mutates=False)
    return {"changed": False, "msg": "Multipath data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}