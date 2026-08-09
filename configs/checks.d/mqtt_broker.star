def _safe_int(s):
    s = s.strip()
    if s == "":
        return 0
    neg = s.startswith("-")
    tmp = s[1:] if neg else s
    if not tmp.isdigit():
        return 0
    v = int(tmp)
    return -v if neg else v

def _safe_float(s):
    s = s.strip()
    if s == "":
        return 0.0
    neg = s.startswith("-")
    tmp = s[1:] if neg else s
    parts = tmp.split(".")
    if len(parts) > 2:
        return 0.0
    valid = True
    for p in parts:
        if p != "" and not p.isdigit():
            valid = False
    if not valid or tmp == "" or tmp == ".":
        return 0.0
    return float(s)

def _collect_sys_topics(ctx, host, port, username, password):
    argv = ["mosquitto_sub", "-h", host, "-p", str(port), "-t", "$SYS/#", "-W", "3", "-v"]
    if username != "":
        argv = argv + ["-u", username, "-P", password]
    res = ctx.run(argv, mutates=False, ok_codes=[0, 1, 3, 27])
    topics = {}
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx > 0:
            topic = line[:idx]
            value = line[idx + 1:].strip()
            topics[topic] = value
    return topics

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 1883)
    username = params.get("username", "")
    password = params.get("password", "")

    if params.get("_discover"):
        topics = _collect_sys_topics(ctx, host, port, username, password)
        subscriptions = _safe_int(topics.get("$SYS/broker/subscriptions/count", ""))
        sockets_rate = _safe_float(topics.get("$SYS/broker/load/sockets/1min", ""))

        if subscriptions > 0 or sockets_rate > 0.0:
            item = "%s:%d" % (host, port)
            return {
                "changed": False,
                "msg": "discovered 1 MQTT broker",
                "data": {"discovery": [
                    {
                        "item": item,
                        "params": {},
                        "metrics": ["subscriptions", "connections_opened_received_rate"],
                    },
                ]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 MQTT brokers",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    use_host = host
    use_port = port
    if ":" in item:
        colon = item.rfind(":")
        use_host = item[:colon]
        port_s = item[colon + 1:]
        if port_s.isdigit():
            use_port = int(port_s)

    topics = _collect_sys_topics(ctx, use_host, use_port, username, password)

    if len(topics) == 0:
        return {
            "changed": False,
            "msg": "no MQTT $SYS data received from " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    subscriptions = _safe_int(topics.get("$SYS/broker/subscriptions/count", ""))
    sockets_rate = _safe_float(topics.get("$SYS/broker/load/sockets/1min", ""))
    version = topics.get("$SYS/broker/version", "unknown")

    metrics = {}
    summary_parts = []

    if subscriptions > 0:
        metrics["subscriptions"] = subscriptions
        summary_parts.append("Subscriptions: %d" % subscriptions)

    if sockets_rate > 0.0:
        conn_per_sec = sockets_rate / 60.0
        metrics["connections_opened_received_rate"] = conn_per_sec
        summary_parts.append("Connections opened: %f/s" % conn_per_sec)

    if len(summary_parts) > 0:
        msg = ", ".join(summary_parts)
    else:
        msg = "MQTT broker reachable, version: %s" % version

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": "Version: %s" % version,
        },
    }