def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["redis-cli", "ping"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "redis not available",
                    "data": {"discovery": []}}
        keys_res = ctx.run(["redis-cli", "keys", "*"], mutates=False)
        if keys_res.rc != 0:
            return {"changed": False, "msg": "redis not available",
                    "data": {"discovery": []}}
        seen = {}
        keys = keys_res.stdout.split() if keys_res.stdout else []
        for key in keys:
            key = key.strip()
            if not key:
                continue
            parts = key.split(".")
            if len(parts) < 3 or parts[1] != "app":
                continue
            site = parts[0]
            application = parts[2]
            if application in ("cmk-broker-test",):
                continue
            item = site + " " + application
            if item not in seen:
                seen[item] = True
                out = [{"item": item, "params": {},
                        "metrics": ["omd_application_messages"]}]
        if not seen:
            return {"changed": False, "msg": "no omd broker queues found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
        return {"changed": False, "msg": "redis not reachable",
                "data": {"discovery": []}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    site, application = item.split(maxsplit=1)
    res = ctx.run(["redis-cli", "ping"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "redis not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    keys_res = ctx.run(["redis-cli", "keys", "*"], mutates=False)
    if keys_res.rc != 0:
        return {"changed": False, "msg": "redis not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    matching_queues = []
    total_messages = 0
    keys = keys_res.stdout.split() if keys_res.stdout else []
    for key in keys:
        key = key.strip()
        if not key:
            continue
        parts = key.split(".")
        if len(parts) < 3 or parts[0] != site or parts[1] != "app" or parts[2] != application:
            continue
        llen_res = ctx.run(["redis-cli", "llen", key], mutates=False)
        if llen_res.rc == 0:
            msg_count = int(llen_res.stdout.strip()) if llen_res.stdout.strip().isdigit() else 0
            total_messages += msg_count
            matching_queues.append((parts[-1], msg_count))
    if not matching_queues:
        return {"changed": False, "msg": "no queues found for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    msg = "Total: %d" % total_messages
    for queue_name, count in matching_queues:
        msg += ", Messages in queue '%s': %d" % (queue_name, count)
    return {"changed": False, "msg": msg,
            "data": {"state": "OK",
                     "metrics": {"omd_application_messages": total_messages},
                     "details": msg}}