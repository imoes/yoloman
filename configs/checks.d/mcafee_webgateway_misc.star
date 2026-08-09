def main(ctx, params):
    section = _gather_section(ctx, params)
    if params.get("_discover"):
        if section == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        items = []
        metrics = []
        if section.get("client_count") != None:
            metrics.append("connections")
        if section.get("socket_count") != None:
            metrics.append("open_network_sockets")
        items.append({"item": "", "params": {"clients": [3200, 3200], "network_sockets": [100000, 100000]}, "metrics": metrics})
        return {"changed": False, "msg": "discovered %d items" % len(items), "data": {"discovery": items}}
    section = _gather_section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "no Web gateway found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics_out = {}
    verdict = "OK"
    msg_parts = []
    if section.get("client_count") != None:
        cc = int(section.get("client_count"))
        w, c = _levels(params.get("clients"), [3200, 3200])
        st = _upper_state(cc, w, c)
        if st == "CRIT":
            verdict = "CRIT"
        elif st == "WARN" and verdict == "OK":
            verdict = "WARN"
        metrics_out["connections"] = cc
        msg_parts.append("Clients: %d" % cc)
    if section.get("socket_count") != None:
        sc = int(section.get("socket_count"))
        w2, c2 = _levels(params.get("network_sockets"), [100000, 100000])
        st2 = _upper_state(sc, w2, c2)
        if st2 == "CRIT":
            verdict = "CRIT"
        elif st2 == "WARN" and verdict == "OK":
            verdict = "WARN"
        metrics_out["open_network_sockets"] = sc
        msg_parts.append("Open network sockets: %d" % sc)
    if len(msg_parts) == 0:
        return {"changed": False, "msg": "no data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": ", ".join(msg_parts), "data": {"state": verdict, "metrics": metrics_out, "details": ""}}

def _gather_section(ctx, params):
    s = _gather_section_via_cli(ctx, params)
    if s != None:
        return s
    s = _gather_section_via_http(ctx, params)
    if s != None:
        return s
    return None

def _gather_section_via_cli(ctx, params):
    res = ctx.run(["mwg-cli", "status"], mutates=False)
    if res.rc != 0:
        return None
    return _parse_mwg_cli_status(ctx, res.stdout)

def _parse_mwg_cli_status(ctx, out):
    client_count = None
    socket_count = None
    lines = out.split("\n")
    for l in lines:
        s = l.strip()
        if s == None or s == "":
            continue
        if s.startswith("Clients:"):
            val = s[len("Clients:"):].strip()
            if val.isdigit():
                client_count = int(val)
        elif s.startswith("Open network sockets:"):
            val = s[len("Open network sockets:"):].strip()
            if val.isdigit():
                socket_count = int(val)
    if client_count == None and socket_count == None:
        return None
    return {"client_count": client_count, "socket_count": socket_count}

def _gather_section_via_http(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    res = ctx.run(["curl", "-sk", "https://%s:%d/mwg-api/status" % (host, port)], mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout:
        return None
    return _parse_http_status(ctx, res.stdout)

def _parse_http_status(ctx, out):
    d = json.decode(out)
    client_count = d.get("client_count")
    socket_count = d.get("socket_count")
    if client_count == None and socket_count == None:
        return None
    return {"client_count": client_count, "socket_count": socket_count}

def _levels(levels, default):
    if levels == None:
        w, c = default
        return w, c
    w = levels[0] if len(levels) > 0 else default[0]
    c = levels[1] if len(levels) > 1 else default[1]
    return w, c

def _upper_state(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"