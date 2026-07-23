def main(ctx, params):
    queue_dir = "/var/lib/nullmailer/queue"
    if not ctx.file_exists(queue_dir):
        return {
            "changed": False,
            "msg": "Nullmailer queue directory not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    queues = []
    for qname in ["deferred", "failed"]:
        qpath = queue_dir + "/" + qname
        if ctx.file_exists(qpath):
            content = ctx.file_read(qpath)
            if content.strip() == "":
                continue
            parts = content.strip().split()
            if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
                size = int(parts[0])
                length = int(parts[1])
                queues.append({"name": qname, "size": size, "length": length})

    if params.get("_discover"):
        items = []
        for q in queues:
            warn = 10 if q["name"] == "deferred" else 1
            crit = 20 if q["name"] == "deferred" else 1
            metrics = ["length", "size"] if q["name"] == "deferred" else ["size"]
            items.append({
                "item": q["name"],
                "params": {"levels": (warn, crit)},
                "metrics": metrics
            })
        return {
            "changed": False,
            "msg": "discovered %d queues" % len(queues),
            "data": {"discovery": items}
        }

    item = params.get("item", "deferred")
    queue = None
    for q in queues:
        if q["name"] == item:
            queue = q
            break

    if queue == None:
        return {
            "changed": False,
            "msg": "queue '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    levels = params.get("levels", None)
    if levels == None:
        if item == "deferred":
            warn_len, crit_len = 10, 20
        else:
            warn_len, crit_len = 1, 1
    else:
        warn_len, crit_len = levels[0], levels[1]

    length = queue["length"]
    size = queue["size"]

    state = "OK"
    if length >= crit_len:
        state = "CRIT"
    elif length >= warn_len:
        state = "WARN"

    size_str = "%d B" % size
    if size >= 1024:
        size_str = "%d KB" % (size // 1024)
        if size >= 1024 * 1024:
            size_str = "%d MB" % (size // (1024 * 1024))

    msg = "%s length: %d mails, size: %s" % (item.capitalize(), length, size_str)

    metrics = {}
    if item == "deferred":
        metrics["length"] = length
    metrics["size"] = size

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }