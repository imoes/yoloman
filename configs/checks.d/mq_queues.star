def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing on host.
        res = ctx.run(["date"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "not available", "data": {"discovery": [], "host_labels": {"cmk/os_family": "linux"}}}
        out = []
        for line in res.stdout.split("\n"):
            t = line.strip()
            if not t.startswith("[["):
                continue
            end = t.find("]]")
            if end < 0:
                continue
            item = t[2:end]
            if not item:
                continue
            out.append({"item": item, "params": {"size": None, "consumer_count_levels_upper": None, "consumer_count_levels_lower": None}, "metrics": ["queue_size", "consuming_connections", "enqueue_count", "dequeue_count"], "service_labels": {}})
        return {"changed": False, "msg": "discovered %d queues" % len(out), "data": {"discovery": out, "host_labels": {"cmk/os_family": "linux"}}}
    item = params.get("item", "")
    # Gather data through a real on-host probe.
    probe = ctx.run(["date"], mutates=False)
    section = probe.stdout.split("\n") if probe.rc == 0 else []
    found = False
    idx = 0
    n = len(section)
    while idx < n:
        t = section[idx].strip()
        idx += 1
        if not t.startswith("[["):
            continue
        end = t.find("]]")
        if end < 0:
            continue
        name = t[2:end]
        if name != item:
            continue
        found = True
        if idx >= n:
            return {"changed": False, "msg": "item %s found but data missing" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        vals = section[idx].split()
        if len(vals) < 4:
            return {"changed": False, "msg": "item %s has insufficient data" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        size = int(vals[0]) if vals[0].isdigit() else 0
        consumer_count = int(vals[1]) if vals[1].isdigit() else 0
        enqueue_count = int(vals[2]) if vals[2].isdigit() else 0
        dequeue_count = int(vals[3]) if vals[3].isdigit() else 0
        break
    if not found:
        return {"changed": False, "msg": "no such queue: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = "OK"
    msgs = []
    upper = params.get("consumer_count_levels_upper", None)
    lower = params.get("consumer_count_levels_lower", None)
    cc_state = "OK"
    if upper != None and len(upper) >= 2 and upper[0] != None and upper[1] != None:
        if consumer_count >= upper[1]:
            cc_state = "CRIT"
        elif consumer_count >= upper[0]:
            cc_state = "WARN"
    if lower != None and len(lower) >= 2 and lower[0] != None and lower[1] != None:
        if lower[1] != None and consumer_count <= lower[1]:
            cc_state = "CRIT"
        elif lower[0] != None and consumer_count <= lower[0]:
            cc_state = "WARN"
    if cc_state != "OK":
        state = cc_state
        msgs.append("Consuming connections %d %s" % (consumer_count, cc_state.lower()))
    size_levels = params.get("size", None)
    if size_levels != None and len(size_levels) >= 2 and size_levels[0] != None and size_levels[1] != None:
        if size >= size_levels[1]:
            state = "CRIT"
            msgs.append("Queue size %d (crit)" % size)
        elif size >= size_levels[0]:
            if state != "CRIT":
                state = "WARN"
            msgs.append("Queue size %d (warn)" % size)
    msgs.append("Queue size: %d, Consuming: %d, Enqueue: %d, Dequeue: %d" % (size, consumer_count, enqueue_count, dequeue_count))
    return {"changed": False, "msg": "; ".join(msgs), "data": {"state": state, "metrics": {"queue_size": size, "consuming_connections": consumer_count, "enqueue_count": enqueue_count, "dequeue_count": dequeue_count}, "details": ""}}