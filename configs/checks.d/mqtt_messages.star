def _parse_uptime(value):
    if value == None or value == "":
        return 0
    scales = {"days": 86400, "hours": 3600, "minutes": 60, "seconds": 1}
    parts = value.strip().split(" ")
    if len(parts) % 2 != 0:
        return 0
    total = 0
    i = 0
    while i < len(parts):
        num = parts[i]
        scale = parts[i+1]
        if not num.isdigit():
            return 0
        total += int(num) * scales.get(scale, 0)
        i = i + 2
    return total

def _parse_int(raw, search_topics):
    i = 0
    while i < len(search_topics):
        t = search_topics[i]
        if t in raw:
            val = raw[t]
            if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
                return int(val)
            return 0
        i = i + 1
    return 0

def _parse_float(raw, search_topics):
    i = 0
    while i < len(search_topics):
        t = search_topics[i]
        if t in raw:
            val = raw[t]
            s = val.strip()
            if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
                return float(val)
            if "." in s:
                s2 = s.replace("-","").replace(".","")
                if s2.isdigit():
                    return float(val)
            return 0.0
        i = i + 1
    return 0.0

def _discover(ctx, params):
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/mqtt_statistics"], mutates=False)
    if res.rc != 0:
        if ctx.file_exists("/var/lib/check-mk-agent/local/mqtt_statistics"):
            content = ctx.file_read("/var/lib/check-mk-agent/local/mqtt_statistics")
            if content == None or content == "":
                return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
            data = json.decode(content) if content != "" else {}
        else:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
    else:
        data = json.decode(res.stdout) if res.stdout != "" else {}

    out = []
    for instance_id, raw in data.items():
        msgs = raw.get("$SYS/broker/messages/received", "")
        connect_rate = raw.get("$SYS/broker/load/connections/1min", "")
        retained = raw.get("$SYS/broker/retained messages/count", "")
        stored_bytes = raw.get("$SYS/broker/store/messages/bytes", "")
        stored_count = raw.get("$SYS/broker/store/messages/count", "")

        if (msgs != "" or connect_rate != "" or retained != "" or stored_bytes != "" or stored_count != ""):
            out.append({
                "item": instance_id,
                "params": {},
                "metrics": [
                    "retained_messages",
                    "stored_messages",
                    "stored_messages_bytes",
                    "connect_messages_received_rate",
                    "messages_received_rate",
                    "messages_sent_rate",
                    "publish_messages_received_rate",
                    "publish_messages_sent_rate",
                ],
            })

    return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

def _check(ctx, params, item):
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/mqtt_statistics"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "data unavailable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout) if res.stdout != "" else {}
    stats = data.get(item)
    if stats == None:
        return {"changed": False, "msg": "instance not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    msgs_recv_total = stats.get("$SYS/broker/messages/received", "")
    msgs_sent_total = stats.get("$SYS/broker/messages/sent", "")
    pub_msgs_recv_total = stats.get("$SYS/broker/publish/messages/received", "")
    pub_msgs_sent_total = stats.get("$SYS/broker/messages/publish/sent", "")
    retained_count = stats.get("$SYS/broker/retained messages/count", "")
    stored_bytes = stats.get("$SYS/broker/store/messages/bytes", "")
    stored_count = stats.get("$SYS/broker/store/messages/count", "")
    connect_rate = stats.get("$SYS/broker/load/connections/1min", "")

    metrics = {}

    if retained_count != "":
        if retained_count.isdigit() or (retained_count.startswith("-") and retained_count[1:].isdigit()):
            v = int(retained_count)
            metrics["retained_messages"] = v

    if stored_count != "":
        if stored_count.isdigit() or (stored_count.startswith("-") and stored_count[1:].isdigit()):
            v = int(stored_count)
            metrics["stored_messages"] = v

    if stored_bytes != "":
        if stored_bytes.isdigit() or (stored_bytes.startswith("-") and stored_bytes[1:].isdigit()):
            v = int(stored_bytes)
            metrics["stored_messages_bytes"] = v

    if connect_rate != "":
        s = connect_rate.strip()
        if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
            v = float(connect_rate) / 60.0
            metrics["connect_messages_received_rate"] = v
        elif "." in s:
            s2 = s.replace("-","").replace(".","")
            if s2.isdigit():
                v = float(connect_rate) / 60.0
                metrics["connect_messages_received_rate"] = v

    if msgs_recv_total != "":
        if msgs_recv_total.isdigit() or (msgs_recv_total.startswith("-") and msgs_recv_total[1:].isdigit()):
            v = int(msgs_recv_total)
            metrics["messages_received_rate"] = v

    if msgs_sent_total != "":
        if msgs_sent_total.isdigit() or (msgs_sent_total.startswith("-") and msgs_sent_total[1:].isdigit()):
            v = int(msgs_sent_total)
            metrics["messages_sent_rate"] = v

    if pub_msgs_recv_total != "":
        if pub_msgs_recv_total.isdigit() or (pub_msgs_recv_total.startswith("-") and pub_msgs_recv_total[1:].isdigit()):
            v = int(pub_msgs_recv_total)
            metrics["publish_messages_received_rate"] = v

    if pub_msgs_sent_total != "":
        if pub_msgs_sent_total.isdigit() or (pub_msgs_sent_total.startswith("-") and pub_msgs_sent_total[1:].isdigit()):
            v = int(pub_msgs_sent_total)
            metrics["publish_messages_sent_rate"] = v

    parts = []
    if "retained_messages" in metrics:
        parts.append("Retained %d" % metrics["retained_messages"])
    if "stored_messages" in metrics:
        parts.append("Stored %d" % metrics["stored_messages"])
    if "stored_messages_bytes" in metrics:
        parts.append("Stored bytes %d" % metrics["stored_messages_bytes"])
    if "connect_messages_received_rate" in metrics:
        parts.append("Conn rate %f/s" % metrics["connect_messages_received_rate"])
    if "messages_received_rate" in metrics:
        parts.append("Msg rx rate %d/s" % metrics["messages_received_rate"])
    if "messages_sent_rate" in metrics:
        parts.append("Msg tx rate %d/s" % metrics["messages_sent_rate"])
    if "publish_messages_received_rate" in metrics:
        parts.append("Pub rx rate %d/s" % metrics["publish_messages_received_rate"])
    if "publish_messages_sent_rate" in metrics:
        parts.append("Pub tx rate %d/s" % metrics["publish_messages_sent_rate"])

    msg = "MQTT %s Messages" % item
    if len(parts) > 0:
        msg = msg + ", " + ", ".join(parts)

    return {"changed": False, "msg": msg, "data": {"state": "OK", "metrics": metrics, "details": ""}}

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    item = params.get("item", "")
    return _check(ctx, params, item)