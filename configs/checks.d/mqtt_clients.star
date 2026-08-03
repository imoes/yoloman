def _parse_uptime(value):
    if not value:
        return 0
    scales = {
        "days": 86400,
        "hours": 3600,
        "minutes": 60,
        "seconds": 1,
    }
    parts = value.strip().split(" ")
    out = 0
    ok = True
    for j in range(0, len(parts) - 1, 2):
        num = parts[j]
        scl = parts[j + 1]
        if num.isdigit() and scl in scales:
            out = out + int(num) * scales[scl]
        else:
            ok = False
            break
    return out if ok and len(parts) >= 2 else 0

def _get_first(raw, search_topics):
    for t in search_topics:
        if t in raw:
            return raw[t]
    return ""

def _parse_int(raw, search_topics):
    v = _get_first(raw, search_topics)
    if v == "":
        return 0
    return int(v) if v.isdigit() else 0

def _parse_float(raw, search_topics):
    v = _get_first(raw, search_topics)
    if v == "":
        return 0.0
    return float(v)

def _collect_sys(ctx, host, timeout):
    res = ctx.run([
        "mosquitto_sub",
        "-h", host,
        "-C", "1",
        "-t", "$SYS/#",
        "-W", str(timeout),
        "-v",
    ], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    raw = {}
    for line in res.stdout.splitlines():
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        topic = line[:sp]
        value = line[sp + 1:]
        raw[topic] = value
    return raw

def _build_stats(ctx, host, timeout):
    raw = _collect_sys(ctx, host, timeout)
    if raw == None:
        return None
    if len(raw) == 0:
        return None
    version = raw.get("$SYS/broker/version", "")
    uptime = _parse_uptime(raw.get("$SYS/broker/uptime", ""))
    socket_rate = _parse_float(raw, ["$SYS/broker/load/sockets/1min"])
    subscriptions = _parse_int(raw, ["$SYS/broker/subscriptions/count"])
    clients = {
        "connected": _parse_int(raw, ["$SYS/broker/clients/connected"]),
        "maximum": _parse_int(raw, ["$SYS/broker/clients/maximum"]),
        "total": _parse_int(raw, ["$SYS/broker/clients/total"]),
    }
    messages = {
        "counters": {
            "bytes_received_total": _parse_int(raw, ["$SYS/broker/bytes/received", "$SYS/broker/load/bytes/received"]),
            "bytes_sent_total": _parse_int(raw, ["$SYS/broker/bytes/sent", "$SYS/broker/load/bytes/sent"]),
            "messages_received_total": _parse_int(raw, ["$SYS/broker/messages/received"]),
            "messages_sent_total": _parse_int(raw, ["$SYS/broker/messages/sent"]),
            "publish_bytes_received_total": _parse_int(raw, ["$SYS/broker/publish/bytes/received"]),
            "publish_bytes_sent_total": _parse_int(raw, ["$SYS/broker/publish/bytes/sent"]),
            "publish_messages_received_total": _parse_int(raw, ["$SYS/broker/publish/messages/received", "$SYS/broker/messages/publish/received"]),
            "publish_messages_sent_total": _parse_int(raw, ["$SYS/broker/publish/messages/sent", "$SYS/broker/messages/publish/sent"]),
        },
        "connect_messages_received_rate": _parse_float(raw, ["$SYS/broker/load/connections/1min"]),
        "retained_messages_count": _parse_int(raw, ["$SYS/broker/retained messages/count"]),
        "stored_messages_bytes": _parse_int(raw, ["$SYS/broker/store/messages/bytes"]),
        "stored_messages_count": _parse_int(raw, ["$SYS/broker/store/messages/count"]),
    }
    return {
        "version": version,
        "uptime": uptime,
        "socket_connections_opened_rate": socket_rate,
        "subscriptions": subscriptions,
        "clients": clients,
        "messages": messages,
    }

def _clients_any(clients):
    return bool(clients["connected"] or clients["maximum"] or clients["total"])

def _level(value, warn, crit):
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    host = params.get("host", "localhost")
    timeout = params.get("timeout", 5)

    if params.get("_discover"):
        res = ctx.run(["mosquitto_sub", "--version"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "mosquitto_sub not installed", "data": {"discovery": []}}
        stats = _build_stats(ctx, host, timeout)
        if stats == None:
            return {"changed": False, "msg": "no MQTT broker $SYS data", "data": {"discovery": []}}
        clients = stats["clients"]
        if not _clients_any(clients):
            return {"changed": False, "msg": "no client data", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 MQTT broker",
            "data": {
                "discovery": [
                    {
                        "item": "localhost",
                        "params": {
                            "warn_connected": params.get("warn_connected"),
                            "crit_connected": params.get("crit_connected"),
                            "warn_maximum": params.get("warn_maximum"),
                            "crit_maximum": params.get("crit_maximum"),
                            "warn_total": params.get("warn_total"),
                            "crit_total": params.get("crit_total"),
                        },
                        "metrics": ["clients_connected", "clients_maximum", "clients_total"],
                    }
                ],
            },
        }

    item = params.get("item", "")
    if item != "localhost":
        return {
            "changed": False,
            "msg": "no such MQTT broker instance: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    stats = _build_stats(ctx, host, timeout)
    if stats == None:
        return {
            "changed": False,
            "msg": "no MQTT broker $SYS data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    clients = stats["clients"]
    if not _clients_any(clients):
        return {
            "changed": False,
            "msg": "MQTT broker reports no connected clients",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    warn_c = params.get("warn_connected")
    crit_c = params.get("crit_connected")
    warn_m = params.get("warn_maximum")
    crit_m = params.get("crit_maximum")
    warn_t = params.get("warn_total")
    crit_t = params.get("crit_total")

    metrics = {
        "clients_connected": clients["connected"],
        "clients_maximum": clients["maximum"],
        "clients_total": clients["total"],
    }

    state = "OK"
    msgs = []
    if clients["connected"]:
        st = _level(clients["connected"], warn_c, crit_c)
        if st == "CRIT":
            state = "CRIT"
        elif st == "WARN" and state != "CRIT":
            state = "WARN"
        msgs.append("Connected clients: %d" % clients["connected"])
    if clients["maximum"]:
        st = _level(clients["maximum"], warn_m, crit_m)
        if st == "CRIT":
            state = "CRIT"
        elif st == "WARN" and state != "CRIT":
            state = "WARN"
        msgs.append("Maximum connected (since startup): %d" % clients["maximum"])
    if clients["total"]:
        st = _level(clients["total"], warn_t, crit_t)
        if st == "CRIT":
            state = "CRIT"
        elif st == "WARN" and state != "CRIT":
            state = "WARN"
        msgs.append("Total connected: %d" % clients["total"])

    if not msgs:
        return {
            "changed": False,
            "msg": "MQTT broker reports no client statistics",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "; ".join(msgs),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "MQTT %s Clients" % item,
        },
    }