def main(ctx, params):
    if params.get("_discover"):
        files = params.get("files", [])
        discovery = []
        for f in files:
            if ctx.file_exists(f):
                discovery.append({
                    "item": f,
                    "params": {},
                    "metrics": ["size", "age"],
                })
        return {
            "changed": False,
            "msg": "discovered %d files" % len(discovery),
            "data": {"discovery": discovery},
        }
    
    item = params.get("item", "")
    # Stat the file
    stat_result = ctx.stat(item)
    if stat_result == None or not stat_result.get("exists"):
        return {
            "changed": False,
            "msg": "file not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    size = stat_result.get("size", 0)
    mtime = stat_result.get("mtime", 0)  # wait, does ctx.stat return mtime?