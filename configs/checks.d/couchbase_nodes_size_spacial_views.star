def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "-u", params.get("username", "Administrator") + ":" + params.get("password", ""),
                       params.get("url", "http://localhost:8091/pools/default/buckets")], mutates=False)
        if res.rc != 0:
            fail("failed to fetch bucket list: " + res.stderr)
        buckets = []
        if res.stdout:
            if json.decode(res.stdout) != None:
                buckets = json.decode(res.stdout)
        items = []
        if type(buckets) == "list":
            for bucket in buckets:
                if type(bucket) == "dict" and bucket.get("name"):
                    items.append({"item": bucket["name"], "params": {}, "metrics": ["size_on_disk", "data_size"]})
        return {"changed": False, "msg": "discovered %d buckets" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    res = ctx.run(["curl", "-s", "-u", params.get("username", "Administrator") + ":" + params.get("password", ""),
                   params.get("url", "http://localhost:8091/pools/default/buckets/%s/stats" % item)], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch stats for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = {}
    if res.stdout:
        decoded = json.decode(res.stdout)
        if decoded != None:
            stats = decoded

    samples = stats.get("op", {}).get("samples", {})
    size_on_disk_raw = samples.get("couch_spatial_disk_size")
    data_size_raw = samples.get("couch_spatial_data_size")

    size_on_disk = None
    if type(size_on_disk_raw) == "list" and len(size_on_disk_raw) > 0:
        size_on_disk = float(size_on_disk_raw[0])

    data_size = None
    if type(data_size_raw) == "list" and len(data_size_raw) > 0:
        data_size = float(data_size_raw[0])

    if size_on_disk == None and data_size == None:
        return {"changed": False, "msg": "no spatial view data found for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size_on_disk_warn = params.get("size_on_disk")
    size_on_disk_crit = params.get("size_on_disk")
    data_size_warn = params.get("size")
    data_size_crit = params.get("size")

    state = "OK"
    details_parts = []

    if size_on_disk != None:
        if size_on_disk_crit != None and type(size_on_disk_crit) == "list" and len(size_on_disk_crit) >= 2:
            if size_on_disk >= float(size_on_disk_crit[1]):
                state = "CRIT"
        if size_on_disk_warn != None and type(size_on_disk_warn) == "list" and len(size_on_disk_warn) >= 2:
            if size_on_disk >= float(size_on_disk_warn[0]) and state == "OK":
                state = "WARN"
        details_parts.append("Size on disk: %s" % render_bytes(size_on_disk))

    if data_size != None:
        if data_size_crit != None and type(data_size_crit) == "list" and len(data_size_crit) >= 2:
            if data_size >= float(data_size_crit[1]):
                state = "CRIT"
        if data_size_warn != None and type(data_size_warn) == "list" and len(data_size_warn) >= 2:
            if data_size >= float(data_size_warn[0]) and state == "OK":
                state = "WARN"
        details_parts.append("Data size: %s" % render_bytes(data_size))

    metrics = {}
    if size_on_disk != None:
        metrics["size_on_disk"] = size_on_disk
    if data_size != None:
        metrics["data_size"] = data_size

    msg = "%s spatial views" % item
    if size_on_disk != None:
        msg += ", Size on disk: %s" % render_bytes(size_on_disk)
    if data_size != None:
        msg += ", Data size: %s" % render_bytes(data_size)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "; ".join(details_parts)}}


def render_bytes(b):
    b = float(b)
    if b >= 1099511627776.0:
        return "%f TiB" % (b / 1099511627776.0)
    elif b >= 1073741824:
        return "%f GiB" % (b / 1073741824)
    elif b >= 1048576:
        return "%f MiB" % (b / 1048576)
    elif b >= 1024:
        return "%f KiB" % (b / 1024)
    return "%f B" % b