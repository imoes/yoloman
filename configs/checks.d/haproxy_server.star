# HAProxy server discovery + check (read-only).
# Reproduces the haproxy_server / haproxy_backend / haproxy_frontend checks
# from the Checkmk haproxy agent section.

# Default status -> state mapping (Checkmk states: 0=OK,1=WARN,2=CRIT,3=UNKNOWN)
DEFAULT_SERVER_STATES = {
    "UP": 0,
    "DOWN": 2,
    "NOLB": 2,
    "MAINT": 2,
    "MAINT (resolution)": 1,
    "MAINT (via)": 1,
    "DRAIN": 2,
    "no check": 2,
}

DEFAULT_FRONTEND_STATES = {
    "OPEN": 0,
    "STOP": 2,
}

HAProxyServerStatus = {
    "UP": "UP",
    "DOWN": "DOWN",
    "NOLB": "NOLB",
    "MAINT": "MAINT",
    "MAINT (resolution)": "MAINT (resolution)",
    "MAINT (via)": "MAINT (via)",
    "DRAIN": "DRAIN",
    "no check": "no check",
}

HAProxyFrontendStatus = {
    "OPEN": "OPEN",
    "STOP": "STOP",
}


def _parse_int(val):
    if val == None:
        return None
    s = val.strip()
    if s == "":
        return None
    neg = False
    body = s
    if s.startswith("-"):
        neg = True
        body = s[1:]
    if body.isdigit():
        v = int(body)
        return -v if neg else v
    return None


def _status_to_enum(status, enum_map):
    if status in enum_map:
        return enum_map[status]
    return status


def _parse_haproxy(string_table):
    backends = {}
    frontends = {}
    servers = {}
    for line in string_table:
        if len(line) <= 32 or line[32] not in ("0", "1", "2"):
            continue
        status = line[17]
        if line[32] == "0":
            name = line[0]
            stot = _parse_int(line[7])
            if stot == None:
                continue
            frontends[name] = {
                "status": _status_to_enum(status, HAProxyFrontendStatus),
                "stot": stot,
            }
        elif line[32] in ("1", "2"):
            uptime = _parse_int(line[23])
            active = _parse_int(line[19])
            backup = _parse_int(line[20])
            stot = _parse_int(line[7])
            if stot == None:
                continue
            if line[32] == "1":
                name = line[0]
                backends[name] = {
                    "status": _status_to_enum(status, HAProxyServerStatus),
                    "uptime": uptime,
                    "active": active,
                    "backup": backup,
                    "stot": stot,
                }
            elif line[32] == "2":
                name = line[0] + "/" + line[1]
                layer_check = line[36]
                servers[name] = {
                    "status": _status_to_enum(status, HAProxyServerStatus),
                    "layer_check": layer_check,
                    "uptime": uptime,
                    "active": active,
                    "backup": backup,
                    "stot": stot,
                }
    return {"backends": backends, "frontends": frontends, "servers": servers}


def _read_stats_socket(ctx):
    sock_res = ctx.run(
        ["curl", "-s", "--unix-socket", "/var/run/haproxy.sock",
         "http:/127.0.0.1/haproxy?stats;csv"],
        mutates=False,
    )
    lines = []
    if sock_res.rc == 0 and sock_res.stdout != "" and sock_res.stdout != None:
        raw = sock_res.stdout
        for ln in raw.splitlines():
            parts = ln.split(",")
            if len(parts) > 0 and (parts[0].startswith("#") or parts[0] == ""):
                continue
            lines.append(parts)
        return lines
    ha_res = ctx.run(["ha", "stats", "csv"], mutates=False)
    if ha_res.rc == 0 and ha_res.stdout != None:
        for ln in ha_res.stdout.splitlines():
            parts = ln.split(",")
            if len(parts) > 0 and parts[0].startswith("#"):
                continue
            lines.append(parts)
        return lines
    return []


def _discover_servers(section):
    out = []
    for key in section["servers"].keys():
        out.append({
            "item": key,
            "params": dict(DEFAULT_SERVER_STATES),
            "metrics": ["session_rate"],
        })
    return out


def _discover_backends(section):
    out = []
    for key in section["backends"].keys():
        out.append({
            "item": key,
            "params": dict(DEFAULT_SERVER_STATES),
            "metrics": ["active_backends", "session_rate"],
        })
    return out


def _discover_frontends(section):
    out = []
    for key in section["frontends"].keys():
        out.append({
            "item": key,
            "params": dict(DEFAULT_FRONTEND_STATES),
            "metrics": ["session_rate"],
        })
    return out


def _format_timespan(seconds):
    s = int(seconds)
    if s < 0:
        s = 0
    d = s // 86400
    h = (s % 86400) // 3600
    m = (s % 3600) // 60
    sec = s % 60
    if d > 0:
        return "%dd %dh %dm" % (d, h, m)
    if h > 0:
        return "%dh %dm %ds" % (h, m, sec)
    if m > 0:
        return "%dm %ds" % (m, sec)
    return "%ds" % sec


def _status_result(status, params, is_frontend):
    if status == None:
        return {"state": "UNKNOWN", "summary": "Unknown status", "metrics": {}, "details": ""}
    enum_map = HAProxyFrontendStatus if is_frontend else HAProxyServerStatus
    is_known = status in enum_map
    if not is_known:
        return {"state": "UNKNOWN", "summary": "Unknown status: " + str(status), "metrics": {}, "details": ""}
    if status in params:
        st = params[status]
        if st == 0:
            label = "OK"
        elif st == 1:
            label = "WARN"
        elif st == 2:
            label = "CRIT"
        else:
            label = "UNKNOWN"
        return {"state": label, "summary": "Status: " + str(status), "metrics": {}, "details": ""}
    return {"state": "WARN", "summary": "Status: " + str(status), "metrics": {}, "details": ""}


def _worst_state(states):
    worst = "OK"
    for s in states:
        if s == "CRIT":
            worst = "CRIT"
        elif s == "WARN" and worst != "CRIT":
            worst = "WARN"
        elif s == "UNKNOWN" and worst not in ("CRIT", "WARN"):
            worst = "UNKNOWN"
    return worst


def _check_server(item, params, section):
    data = section["servers"].get(item)
    if data == None:
        return {"state": "UNKNOWN", "summary": "no such server", "metrics": {}, "details": ""}
    results = []
    results.append(_status_result(data["status"], params, False))
    active = data["active"]
    backup = data["backup"]
    if active:
        results.append({"state": "OK", "summary": "Active", "metrics": {}, "details": ""})
    elif backup:
        results.append({"state": "OK", "summary": "Backup", "metrics": {}, "details": ""})
    else:
        results.append({"state": "CRIT", "summary": "Neither active nor backup", "metrics": {}, "details": ""})
    results.append({"state": "OK", "summary": "Layer Check: " + str(data["layer_check"]), "metrics": {}, "details": ""})
    uptime = data["uptime"]
    if uptime != None:
        stateStr = "UP"
        if isinstance(data["status"], str):
            stateStr = data["status"]
        results.append({"state": "OK", "summary": stateStr + " since " + _format_timespan(uptime), "metrics": {}, "details": ""})
    merged_metrics = {}
    stot = data["stot"]
    if stot:
        merged_metrics["session_rate"] = stot
    states = []
    summary_parts = []
    for r in results:
        states.append(r["state"])
        summary_parts.append(r["summary"])
        for k, v in r["metrics"].items():
            merged_metrics[k] = v
    worst = _worst_state(states)
    return {"state": worst, "summary": ", ".join(summary_parts), "metrics": merged_metrics, "details": ""}


def _check_backend(item, params, section):
    data = section["backends"].get(item)
    if data == None:
        return {"state": "UNKNOWN", "summary": "no such backend", "metrics": {}, "details": ""}
    results = []
    results.append(_status_result(data["status"], params, False))
    active = data["active"]
    backup = data["backup"]
    if active:
        results.append({"state": "OK", "summary": "Active", "metrics": {"active_backends": active}, "details": ""})
    elif backup:
        results.append({"state": "OK", "summary": "Backup", "metrics": {}, "details": ""})
    else:
        results.append({"state": "OK", "summary": "Neither active nor backup", "metrics": {}, "details": ""})
    uptime = data["uptime"]
    if uptime != None:
        stateStr = "UP"
        if isinstance(data["status"], str):
            stateStr = data["status"]
        results.append({"state": "OK", "summary": stateStr + " since " + _format_timespan(uptime), "metrics": {}, "details": ""})
    merged_metrics = {}
    stot = data["stot"]
    if stot:
        merged_metrics["session_rate"] = stot
    if active:
        merged_metrics["active_backends"] = active
    states = []
    summary_parts = []
    for r in results:
        states.append(r["state"])
        summary_parts.append(r["summary"])
        for k, v in r["metrics"].items():
            merged_metrics[k] = v
    worst = _worst_state(states)
    return {"state": worst, "summary": ", ".join(summary_parts), "metrics": merged_metrics, "details": ""}


def _check_frontend(item, params, section):
    data = section["frontends"].get(item)
    if data == None:
        return {"state": "UNKNOWN", "summary": "no such frontend", "metrics": {}, "details": ""}
    results = []
    results.append(_status_result(data["status"], params, True))
    merged_metrics = {}
    stot = data["stot"]
    if stot:
        merged_metrics["session_rate"] = stot
    states = []
    summary_parts = []
    for r in results:
        states.append(r["state"])
        summary_parts.append(r["summary"])
        for k, v in r["metrics"].items():
            merged_metrics[k] = v
    worst = _worst_state(states)
    return {"state": worst, "summary": ", ".join(summary_parts), "metrics": merged_metrics, "details": ""}


def main(ctx, params):
    ha_res = ctx.run(["ha", "--version"], mutates=False)
    sock_stat = ctx.stat("/var/run/haproxy.sock")
    has_ha = ha_res.rc == 0
    has_sock = (sock_stat != None) and sock_stat.get("exists", False)
    if not has_ha and not has_sock:
        return {"changed": False, "msg": "HAProxy not installed", "data": {"discovery": []}}
    if params.get("_discover"):
        lines = _read_stats_socket(ctx)
        section = _parse_haproxy(lines)
        kind = params.get("kind", "server")
        if kind == "server":
            discovery = _discover_servers(section)
        elif kind == "backend":
            discovery = _discover_backends(section)
        elif kind == "frontend":
            discovery = _discover_frontends(section)
        else:
            discovery = _discover_servers(section)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery,
                     "host_labels": {"cmk/haproxy_kind": kind}},
        }
    item = params.get("item", "")
    kind = params.get("kind", "server")
    lines = _read_stats_socket(ctx)
    section = _parse_haproxy(lines)
    if kind == "server":
        params_used = dict(DEFAULT_SERVER_STATES)
    elif kind == "backend":
        params_used = dict(DEFAULT_SERVER_STATES)
    else:
        params_used = dict(DEFAULT_FRONTEND_STATES)
    if kind == "server":
        result = _check_server(item, params_used, section)
    elif kind == "backend":
        result = _check_backend(item, params_used, section)
    else:
        result = _check_frontend(item, params_used, section)
    return {
        "changed": False,
        "msg": result["summary"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"],
        },
    }