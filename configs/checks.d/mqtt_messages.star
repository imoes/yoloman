# Copyright (C) 2021 Checkmk GmbH - License: GNU General Public License v2
# Translated for the yolo-man agent.

def _to_int(v):
    s = str(v).strip()
    if s == None or s == "":
        return 0
    neg = False
    cur = s
    if cur.startswith("-"):
        neg = True
        cur = cur[1:]
    if not cur.isdigit():
        return 0
    n = 0
    for ch in cur:
        n = n * 10 + (ord(ch) - 48)
    return -n if neg else n

def _to_float(v):
    s = str(v).strip()
    if s == None or s == "":
        return 0.0
    neg = False
    cur = s
    if cur.startswith("-"):
        neg = True
        cur = cur[1:]
    if "." in cur:
        whole_part = cur.split(".", 1)[0]
        frac_part = cur.split(".", 1)[1]
    else:
        whole_part = cur
        frac_part = ""
    if whole_part == "" and frac_part == "":
        return 0.0
    if not whole_part.isdigit() and whole_part != "":
        return 0.0
    if not frac_part.isdigit() and frac_part != "":
        return 0.0
    whole = 0
    for ch in whole_part:
        whole = whole * 10 + (ord(ch) - 48)
    frac = 0
    scale = 1
    for ch in frac_part:
        frac = frac * 10 + (ord(ch) - 48)
        scale = scale * 10
    val = whole + (frac / scale) if scale else float(whole)
    return -val if neg else val

def _parse_uptime(value):
    if value == None or value == "":
        return 0
    scales = {
        "days": 86400,
        "hours": 3600,
        "minutes": 60,
        "seconds": 1,
    }
    parts = value.strip().split(" ")
    if len(parts) == 0:
        return 0
    total = 0
    i = 0
    while i < len(parts):
        num_str = parts[i]
        scale_str = parts[i + 1] if (i + 1) < len(parts) else ""
        if num_str.isdigit() and scale_str in scales:
            total = total + int(num_str) * scales[scale_str]
            i = i + 2
        else:
            i = i + 1
    return total

def _get_first(raw, search_topics):
    for t in search_topics:
        if t in raw:
            return raw[t]
    return ""

def _parse_int(raw, search_topics):
    v = _get_first(raw, search_topics)
    if v == None or v == "":
        return 0
    s = str(v).strip()
    if s == "" or s == None:
        return 0
    neg = False
    cur = s
    if cur.startswith("-"):
        neg = True
        cur = cur[1:]
    if not cur.isdigit():
        return 0
    n = 0
    for ch in cur:
        n = n * 10 + (ord(ch) - 48)
    return -n if neg else n

def _parse_float(raw, search_topics):
    v = _get_first(raw, search_topics)
    if v == None or v == "":
        return 0.0
    s = str(v).strip()
    if s == "" or s == None:
        return 0.0
    neg = False
    cur = s
    if cur.startswith("-"):
        neg = True
        cur = cur[1:]
    if "." in cur:
        whole_part = cur.split(".", 1)[0]
        frac_part = cur.split(".", 1)[1]
    else:
        whole_part = cur
        frac_part = ""
    if whole_part == "" and frac_part == "":
        return 0.0
    if not whole_part.isdigit() and whole_part != "":
        return 0.0
    if not frac_part.isdigit() and frac_part != "":
        return 0.0
    whole = 0
    for ch in whole_part:
        whole = whole * 10 + (ord(ch) - 48)
    frac = 0
    scale = 1
    for ch in frac_part:
        frac = frac * 10 + (ord(ch) - 48)
        scale = scale * 10
    val = whole + (frac / scale) if scale else float(whole)
    return -val if neg else val

def _gather_raw(ctx):
    res = ctx.run(["mosquitto_sub", "-v", "-h", "localhost", "-p", 1883, "$SYS/#"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    if res.stdout == None or res.stdout == "":
        return None
    raw = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            topic = parts[0].strip()
            value = parts[1].strip()
            raw[topic] = value
        elif len(parts) == 1 and parts[0].strip() != "":
            raw[parts[0].strip()] = ""
    return raw

def _gather_stats(ctx):
    raw = _gather_raw(ctx)
    if raw == None:
        return None
    counters = {
        "bytes_received_total": _parse_int(raw, ["$SYS/broker/bytes/received", "$SYS/broker/load/bytes/received"]),
        "bytes_sent_total": _parse_int(raw, ["$SYS/broker/bytes/sent", "$SYS/broker/load/bytes/sent"]),
        "messages_received_total": _parse_int(raw, ["$SYS/broker/messages/received"]),
        "messages_sent_total": _parse_int(raw, ["$SYS/broker/messages/sent"]),
        "publish_bytes_received_total": _parse_int(raw, ["$SYS/broker/publish/bytes/received"]),
        "publish_bytes_sent_total": _parse_int(raw, ["$SYS/broker/publish/bytes/sent"]),
        "publish_messages_received_total": _parse_int(raw, ["$SYS/broker/publish/messages/received", "$SYS/broker/messages/publish/received"]),
        "publish_messages_sent_total": _parse_int(raw, ["$SYS/broker/publish/messages/sent", "$SYS/broker/messages/publish/sent"]),
    }
    messages = {
        "counters": counters,
        "connect_messages_received_rate": _parse_float(raw, ["$SYS/broker/load/connections/1min"]),
        "retained_messages_count": _parse_int(raw, ["$SYS/broker/retained messages/count"]),
        "stored_messages_bytes": _parse_int(raw, ["$SYS/broker/store/messages/bytes"]),
        "stored_messages_count": _parse_int(raw, ["$SYS/broker/store/messages/count"]),
    }
    stats = {
        "version": raw.get("$SYS/broker/version", ""),
        "uptime": _parse_uptime(raw.get("$SYS/broker/uptime", "")),
        "socket_connections_opened_rate": _parse_float(raw, ["$SYS/broker/load/sockets/1min"]),
        "subscriptions": _parse_int(raw, ["$SYS/broker/subscriptions/count"]),
        "clients": {
            "connected": _parse_int(raw, ["$SYS/broker/clients/connected"]),
            "maximum": _parse_int(raw, ["$SYS/broker/clients/maximum"]),
            "total": _parse_int(raw, ["$SYS/broker/clients/total"]),
        },
        "messages": messages,
    }
    return {"localhost": stats}

METRIC_TITLES = {
    "bytes_received_rate": "Bytes Received Rate",
    "bytes_sent_rate": "Bytes Sent Rate",
    "messages_received_rate": "Messages Received Rate",
    "messages_sent_rate": "Messages Sent Rate",
    "publish_bytes_received_rate": "Publish Bytes Received Rate",
    "publish_bytes_sent_rate": "Publish Bytes Sent Rate",
    "publish_messages_received_rate": "Publish Messages Received Rate",
    "publish_messages_sent_rate": "Publish Messages Sent Rate",
    "connect_messages_received_rate": "Connect Messages Received Rate",
}

def main(ctx, params):
    if params.get("_discover"):
        raw = _gather_raw(ctx)
        if raw == None:
            return {"changed": False, "msg": "mosquitto_sub not installed or no MQTT broker found", "data": {"discovery": []}}
        counters_any = (
            _parse_int(raw, ["$SYS/broker/bytes/received", "$SYS/broker/load/bytes/received"]) or
            _parse_int(raw, ["$SYS/broker/bytes/sent", "$SYS/broker/load/bytes/sent"]) or
            _parse_int(raw, ["$SYS/broker/messages/received"]) or
            _parse_int(raw, ["$SYS/broker/messages/sent"]) or
            _parse_int(raw, ["$SYS/broker/publish/bytes/received"]) or
            _parse_int(raw, ["$SYS/broker/publish/bytes/sent"]) or
            _parse_int(raw, ["$SYS/broker/publish/messages/received", "$SYS/broker/messages/publish/received"]) or
            _parse_int(raw, ["$SYS/broker/publish/messages/sent", "$SYS/broker/messages/publish/sent"])
        )
        connect_rate = _parse_float(raw, ["$SYS/broker/load/connections/1min"])
        retained = _parse_int(raw, ["$SYS/broker/retained messages/count"])
        stored_bytes = _parse_int(raw, ["$SYS/broker/store/messages/bytes"])
        stored_count = _parse_int(raw, ["$SYS/broker/store/messages/count"])
        if not (counters_any or connect_rate or retained or stored_bytes or stored_count):
            return {"changed": False, "msg": "no MQTT broker found", "data": {"discovery": []}}
        metrics = ["retained_messages", "stored_messages", "stored_messages_bytes",
                   "bytes_received_rate", "bytes_sent_rate", "messages_received_rate",
                   "messages_sent_rate", "publish_bytes_received_rate", "publish_bytes_sent_rate",
                   "publish_messages_received_rate", "publish_messages_sent_rate",
                   "connect_messages_received_rate"]
        discovery = [{"item": "localhost", "params": {}, "metrics": metrics}]
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _gather_stats(ctx)
    if section == None:
        return {"changed": False, "msg": "mosquitto_sub not installed or no MQTT broker found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    stats = section.get(item)
    if stats == None:
        return {"changed": False, "msg": "no such MQTT instance: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_lines = []
    state = "OK"
    if stats.subscriptions:
        warn = params.get("subscriptions_warn")
        crit = params.get("subscriptions_crit")
        val = stats.subscriptions
        metrics["subscriptions"] = val
        details_lines.append("Subscriptions: %d" % val)
        if crit != None and val >= crit:
            state = "CRIT"
        elif warn != None and val >= warn:
            state = "WARN"
    socket_rate = stats.socket_connections_opened_rate
    if socket_rate:
        per_sec = socket_rate / 60
        metrics["socket_connections_opened_rate"] = per_sec
        details_lines.append("Socket connections opened: %f/s" % per_sec)
    messages = stats.messages
    if messages.retained_messages_count:
        warn = params.get("retained_messages_warn")
        crit = params.get("retained_messages_crit")
        val = messages.retained_messages_count
        metrics["retained_messages"] = val
        details_lines.append("Retained messages: %d" % val)
        if crit != None and val >= crit:
            state = "CRIT"
        elif warn != None and val >= warn:
            state = "WARN"
    if messages.stored_messages_count:
        warn = params.get("stored_messages_warn")
        crit = params.get("stored_messages_crit")
        val = messages.stored_messages_count
        metrics["stored_messages"] = val
        details_lines.append("Stored messages: %d" % val)
        if crit != None and val >= crit:
            state = "CRIT"
        elif warn != None and val >= warn:
            state = "WARN"
    if messages.stored_messages_bytes:
        warn = params.get("stored_messages_bytes_warn")
        crit = params.get("stored_messages_bytes_crit")
        val = messages.stored_messages_bytes
        metrics["stored_messages_bytes"] = val
        details_lines.append("Stored message bytes: %d" % val)
        if crit != None and val >= crit:
            state = "CRIT"
        elif warn != None and val >= warn:
            state = "WARN"
    if messages.connect_messages_received_rate:
        per_sec = messages.connect_messages_received_rate / 60
        metrics["connect_messages_received_rate"] = per_sec
        details_lines.append("Connect messages received: %f/s" % per_sec)
    counter_keys = sorted(messages.counters.keys())
    for k in counter_keys:
        v = messages.counters[k]
        if not v:
            continue
        rate_key = k.replace("_total", "_rate")
        metrics[rate_key] = float(v)
        details_lines.append(METRIC_TITLES.get(rate_key, rate_key) + ": %s" % str(v))
    rate_vals = [v for v in metrics.values() if type(v) == "float" and v > 0]
    any_rate = len(rate_vals) > 0
    if any_rate:
        for mk in metrics.keys():
            if mk.endswith("_rate"):
                warn = params.get(mk + "_warn")
                crit = params.get(mk + "_crit")
                val = metrics[mk]
                if crit != None and val >= crit:
                    state = "CRIT"
                elif warn != None and val >= warn:
                    state = "WARN"
    msg = "MQTT %s Messages: %s" % (item, "; ".join(details_lines)) if details_lines else "MQTT %s Messages" % item
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "\n".join(details_lines)}}