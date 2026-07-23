def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": {"clients": None, "network_sockets": None},
                 "metrics": ["connections", "open_network_sockets"]}
            ]},
        }

    counts_path = "/var/lib/mcafee/webgateway/counts.json"
    if not ctx.file_exists(counts_path):
        return {
            "changed": False,
            "msg": "data file missing: " + counts_path,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    content = ctx.file_read(counts_path)
    if not content.strip():
        return {
            "changed": False,
            "msg": "data file empty: " + counts_path,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = json.decode(content)

    client_count = data.get("client_count")
    socket_count = data.get("socket_count")

    clients_warn = params.get("clients")
    sockets_warn = params.get("network_sockets")

    state = "OK"
    details_parts = []

    if client_count != None:
        value = client_count
        warn = clients_warn
        label = "Clients"
        if warn != None and value >= warn:
            state = "WARN"
        details_parts.append("%s: %s" % (label, str(value)))
    else:
        details_parts.append("Clients: not available")

    if socket_count != None:
        value = socket_count
        warn = sockets_warn
        label = "Open network sockets"
        if warn != None and value >= warn:
            state = "WARN"
        details_parts.append("%s: %s" % (label, str(value)))
    else:
        details_parts.append("Open network sockets: not available")

    metrics = {}
    if client_count != None:
        metrics["connections"] = client_count
    if socket_count != None:
        metrics["open_network_sockets"] = socket_count

    msg = ", ".join(details_parts)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }