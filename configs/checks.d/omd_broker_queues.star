def _node_to_site(node):
    at = node.find("@")
    if at >= 0:
        return node[at + 1:]
    return node

def main(ctx, params):
    res = ctx.run(
        ["rabbitmqctl", "list_queues", "-q", "--formatter", "json",
         "name", "vhost", "messages", "node"],
        mutates=False,
        ok_codes=[0, 1, 2],
    )

    broker_ok = (res.rc == 0) and (res.stdout.strip() != "")
    queues_raw = json.decode(res.stdout.strip()) if broker_ok else []
    if type(queues_raw) != "list":
        queues_raw = []

    # Build item-key → [queue-dict] map; only vhost="/" and name matching *.app.*
    site_app_queues = {}
    for q in queues_raw:
        vhost = str(q.get("vhost", ""))
        name = str(q.get("name", ""))
        node = str(q.get("node", ""))
        messages = int(q.get("messages", 0))

        if vhost != "/":
            continue
        qparts = name.split(".")
        if len(qparts) < 3 or qparts[1] != "app":
            continue

        application = qparts[2]
        site = _node_to_site(node)
        key = site + " " + application
        if key not in site_app_queues:
            site_app_queues[key] = []
        site_app_queues[key].append({"name": name, "messages": messages})

    if params.get("_discover"):
        if not broker_ok:
            return {"changed": False, "msg": "broker unavailable",
                    "data": {"discovery": []}}
        discovery = []
        for key in sorted(site_app_queues.keys()):
            app = key.split(" ", 1)[1] if " " in key else key
            if app == "cmk-broker-test":
                continue
            discovery.append({
                "item": key,
                "params": {},
                "metrics": ["omd_application_messages"],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    if not broker_ok:
        return {"changed": False, "msg": "broker unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    matching = site_app_queues.get(item)

    if matching == None:
        return {"changed": False, "msg": "queue not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total = 0
    for q in matching:
        total += q["messages"]

    detail_lines = []
    for q in matching:
        qparts = q["name"].split(".")
        short = qparts[-1] if len(qparts) > 0 else q["name"]
        detail_lines.append("Messages in queue '%s': %d" % (short, q["messages"]))

    return {
        "changed": False,
        "msg": "Queued application messages: %d" % total,
        "data": {
            "state": "OK",
            "metrics": {"omd_application_messages": total},
            "details": "; ".join(detail_lines),
        },
    }