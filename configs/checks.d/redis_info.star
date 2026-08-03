# Checkmk redis_info -> read-only Starlark check module
def _is_int(s):
    s = s.strip()
    if s == "" or s == "-":
        return False
    body = s[1:] if s[0] in "+-" else s
    if body == "":
        return False
    return body.isdigit()

def _is_float(s):
    s = s.strip()
    if s == "":
        return False
    body = s
    if body[0] in "+-":
        body = body[1:]
    if body == "":
        return False
    parts = body.split(".")
    if len(parts) == 2:
        intp, frac = parts
        if intp == "" and frac == "":
            return False
        if intp == "":
            return frac.isdigit()
        if frac == "":
            return intp.isdigit()
        return intp.isdigit() and frac.isdigit()
    if len(parts) == 1:
        return body.isdigit()
    return False

def _to_number(raw):
    raw = raw.strip()
    if _is_int(raw):
        return int(raw)
    if _is_float(raw):
        return float(raw)
    if raw.lower() in ("nan", "inf", "-inf", "+inf", "infinity"):
        return None
    return None

def _parse_section(text):
    parsed = {}
    instance = {}
    inst_section = {}
    if not text:
        return parsed
    for line in text.splitlines():
        parts = line.split(" ", 1)
        first = parts[0] if parts else ""
        rest = parts[1] if len(parts) > 1 else ""
        rest = rest.strip()
        if first.startswith("[[[") and first.endswith("]]]"):
            inner = first[3:-3]
            name, host, port = inner.split("|")
            instance = parsed.setdefault(name.replace(";", ":"), {"host": host, "port": port})
            inst_section = {}
            continue
        if not instance:
            continue
        if first == "error":
            instance["error"] = rest if rest else ""
            continue
        if first.startswith("#"):
            inst_section = instance.setdefault(first.split()[-1], {})
            continue
        n = _to_number(rest)
        if n != None:
            inst_section[first] = n
        else:
            inst_section[first] = rest
    return parsed

def _redis_info(ctx, host, port, unix_sock):
    if unix_sock:
        return ctx.run(["redis-cli", "-s", unix_sock, "info"], mutates=False)
    return ctx.run(["redis-cli", "-h", host, "-p", port, "info"], mutates=False)

def _find_instances(ctx):
    rc = ctx.run(["redis-cli", "--version"], mutates=False)
    if rc == None or rc.rc == 127 or not rc.stdout:
        return []
    found = []
    for sock in ["/var/run/redis/redis-server.sock", "/run/redis/redis-server.sock",
                 "/var/run/redis/redis.sock", "/tmp/redis.sock"]:
        if ctx.file_exists(sock):
            found.append(("unix-socket", "unix-socket", "unix-socket", sock))
    for port in [6379, 6380, 6381, 6382]:
        r = ctx.run(["redis-cli", "-h", "127.0.0.1", "-p", str(port), "ping"], mutates=False)
        if r.rc == 0 and (r.stdout or "").strip().startswith("PONG"):
            found.append(("127.0.0.1:" + str(port), "127.0.0.1", str(port), ""))
    return found

def _discover_section(ctx):
    instances = _find_instances(ctx)
    if not instances:
        return None
    lines = []
    for name, host, port, unix_sock in instances:
        lines.append("[[[[" + name + "|" + host + "|" + port + "]]]")
        res = _redis_info(ctx, host, port, unix_sock)
        if res.rc != 0:
            err = (res.stderr or res.stdout or "").strip()
            lines.append("error " + err)
            continue
        out = res.stdout or ""
        for ln in out.splitlines():
            stripped = ln.strip()
            if not stripped:
                continue
            if stripped.startswith("%"):
                continue
            if stripped.startswith("#"):
                if ":" in stripped:
                    sec = stripped.lstrip("# ").split(":")[0].strip()
                    lines.append("# " + sec)
                continue
            if ":" in stripped:
                k, v = stripped.split(":", 1)
                lines.append(k + " " + v)
    text = "\n".join(lines)
    return _parse_section(text)

def _as_int(v):
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v)
    if str(v).lstrip("-").isdigit():
        return int(v)
    return 0

def _worst_of(states):
    worst = "OK"
    for s in states:
        if s == "CRIT":
            worst = "CRIT"
        elif s == "WARN" and worst != "CRIT":
            worst = "WARN"
    return worst

def _summary_join(parts):
    out = ""
    for i in range(len(parts)):
        if i == 0:
            out = parts[i]
        else:
            out = out + "; " + parts[i]
    return out

def main(ctx, params):
    if params.get("_discover"):
        section = _discover_section(ctx)
        if section == None:
            return {"changed": False, "msg": "no redis instance found",
                    "data": {"discovery": []}}
        out = []
        keys = sorted(section.keys())
        for item in keys:
            item_data = section.get(item, {})
            metrics = []
            server = item_data.get("Server") if isinstance(item_data, dict) else None
            if server != None:
                if server.get("uptime_in_seconds") != None:
                    metrics.append("uptime_seconds")
                if server.get("connected_clients") != None:
                    metrics.append("connected_clients")
                if server.get("used_memory") != None:
                    metrics.append("used_memory")
                if server.get("used_memory_rss") != None:
                    metrics.append("used_memory_rss")
                if server.get("total_net_input_bytes") != None:
                    metrics.append("total_net_input_bytes")
                if server.get("total_net_output_bytes") != None:
                    metrics.append("total_net_output_bytes")
                if server.get("instantaneous_ops_per_sec") != None:
                    metrics.append("instantaneous_ops_per_sec")
            out.append({"item": item,
                        "params": {"expected_mode": params.get("expected_mode", "")},
                        "metrics": metrics})
        return {"changed": False, "msg": "discovered %d redis instances" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    section = _discover_section(ctx)
    if section == None or item not in section:
        return {"changed": False, "msg": "no redis instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    item_data = section.get(item, {})
    if not isinstance(item_data, dict):
        return {"changed": False, "msg": "invalid redis instance data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item_data.get("error") != None:
        msg = "Error: " + str(item_data.get("error"))
        return {"changed": False, "msg": msg,
                "data": {"state": "CRIT", "metrics": {}, "details": msg}}

    server = item_data.get("Server")
    if server == None:
        return {"changed": False, "msg": "no Server section for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summaries = []
    states = []
    metrics = {}

    server_mode = server.get("redis_mode")
    if server_mode != None:
        mode_state = "OK"
        infotext = "Mode: " + str(server_mode).title()
        expected_mode = params.get("expected_mode")
        if expected_mode != None and expected_mode != "":
            if expected_mode != server_mode:
                mode_state = "WARN"
                infotext += " (expected: " + str(expected_mode).title() + ")"
        summaries.append(infotext)
        states.append(mode_state)

    uptime = server.get("uptime_in_seconds")
    if uptime != None:
        metrics["uptime_seconds"] = _as_int(uptime)

    clients = server.get("connected_clients")
    if clients != None:
        metrics["connected_clients"] = _as_int(clients)

    mem = server.get("used_memory")
    if mem != None:
        metrics["used_memory"] = _as_int(mem)

    memrss = server.get("used_memory_rss")
    if memrss != None:
        metrics["used_memory_rss"] = _as_int(memrss)

    netin = server.get("total_net_input_bytes")
    if netin != None:
        metrics["total_net_input_bytes"] = _as_int(netin)

    netout = server.get("total_net_output_bytes")
    if netout != None:
        metrics["total_net_output_bytes"] = _as_int(netout)

    ops = server.get("instantaneous_ops_per_sec")
    if ops != None:
        metrics["instantaneous_ops_per_sec"] = _as_int(ops)

    for key, label in [
        ("redis_version", "Version"),
        ("gcc_version", "GCC compiler version"),
        ("process_id", "PID"),
    ]:
        value = server.get(key)
        if value != None:
            summaries.append(label + ": " + str(value))
            states.append("OK")

    host_data = item_data.get("host")
    if host_data != None:
        addr = "Socket" if item_data.get("port") == "unix-socket" else "IP"
        summaries.append(addr + ": " + str(host_data))
        states.append("OK")

    port_data = item_data.get("port")
    if port_data != None and port_data != "unix-socket":
        summaries.append("Port: " + str(port_data))
        states.append("OK")

    summary = _summary_join(summaries) if summaries else "no data"
    worst = _worst_of(states) if states else "OK"
    return {"changed": False, "msg": summary,
            "data": {"state": worst, "metrics": metrics, "details": ""}}