# Default server states: status_name -> state value (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
# From check_default_parameter for haproxy_server/backend
_DEFAULT_SERVER_PARAMS = {
    "UP": 0,
    "DOWN": 2,
    "NOLB": 2,
    "MAINT": 2,
    "MAINT_VIA": 1,
    "MAINT_RES": 1,
    "DRAIN": 2,
    "NO_CHECK": 2,
}

# HAProxy show stat CSV column indices (per HAProxy documentation)
_COL_STATUS = 17
_COL_STOT = 7
_COL_UPTIME = 23
_COL_ACTIVE = 19
_COL_BACKUP = 20
_COL_TYPE = 32

def _parse_int(val):
    if val == None or val == "":
        return None
    cleaned = val.lstrip("-")
    if cleaned.isdigit():
        return int(val)
    return None

def _get_stats_via_python(ctx, socket_path):
    script_lines = [
        "import socket, sys, time",
        "s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)",
        "s.settimeout(5)",
        "s.connect(sys.argv[1])",
        "s.send(b'show stat\\n')",
        "time.sleep(1)",
        "data = b''",
        "while True:",
        "    chunk = s.recv(65536)",
        "    if not chunk:",
        "        break",
        "    data += chunk",
        "sys.stdout.write(data.decode('utf-8', 'replace'))",
        "s.close()",
    ]
    script = "\n".join(script_lines)
    res = ctx.run(["python3", "-c", script, socket_path], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return None
    return res.stdout

def _find_haproxy_socket(ctx, explicit_path):
    if explicit_path != None and ctx.file_exists(explicit_path):
        return explicit_path
    for path in ["/var/run/haproxy/haproxy.sock", "/var/run/haproxy.sock", "/run/haproxy/haproxy.sock", "/tmp/haproxy.sock"]:
        if ctx.file_exists(path):
            return path
    return None

def _parse_haproxy_csv(csv_text):
    rows = []
    for line in csv_text.splitlines():
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            continue
        fields = line.split(",")
        rows.append(fields)
    return rows

def _build_backend_dict(rows):
    backends = {}
    for fields in rows:
        if len(fields) <= _COL_TYPE:
            continue
        if fields[_COL_TYPE] != "1":
            continue

        stot_str = fields[_COL_STOT]
        if not _parse_int(stot_str) != None and not stot_str.lstrip("-").isdigit():
            continue
        stot = _parse_int(stot_str)
        if stot == None:
            continue

        name = fields[0]
        if name == "" or name.startswith("~"):
            continue

        status_str = fields[_COL_STATUS]
        uptime = _parse_int(fields[_COL_UPTIME])
        active = _parse_int(fields[_COL_ACTIVE])
        backup = _parse_int(fields[_COL_BACKUP])
        backends[name] = {
            "status": status_str,
            "uptime": uptime,
            "active": active,
            "backup": backup,
            "stot": stot,
        }
    return backends

def _state_from_level(level_val):
    if level_val == 0:
        return "OK"
    if level_val == 1:
        return "WARN"
    if level_val == 2:
        return "CRIT"
    return "UNKNOWN"

def main(ctx, params):
    if params.get("_discover"):
        socket_path = _find_haproxy_socket(ctx, params.get("socket"))
        if socket_path == None:
            return {"changed": False, "msg": "no HAProxy socket found",
                    "data": {"discovery": []}}

        csv_text = _get_stats_via_python(ctx, socket_path)
        if csv_text == None:
            return {"changed": False, "msg": "HAProxy not reachable",
                    "data": {"discovery": []}}

        rows = _parse_haproxy_csv(csv_text)
        backends = _build_backend_dict(rows)

        discovery = []
        for name in backends.keys():
            p = {}
            for k in _DEFAULT_SERVER_PARAMS.keys():
                p[k] = _DEFAULT_SERVER_PARAMS[k]
            discovery.append({
                "item": name,
                "params": p,
                "metrics": ["active", "backup", "stot"],
            })

        return {"changed": False,
                "msg": "discovered %d backends" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    socket_path = _find_haproxy_socket(ctx, params.get("socket"))

    if socket_path == None:
        return {"changed": False,
                "msg": "no HAProxy socket found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no HAProxy socket found"}}

    csv_text = _get_stats_via_python(ctx, socket_path)
    if csv_text == None:
        return {"changed": False,
                "msg": "HAProxy not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "HAProxy not reachable"}}

    rows = _parse_haproxy_csv(csv_text)
    backends = _build_backend_dict(rows)
    backend = backends.get(item)

    if backend == None:
        return {"changed": False,
                "msg": "backend %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "backend %s not found" % item}}

    params_map = {}
    for k in _DEFAULT_SERVER_PARAMS.keys():
        params_map[k] = _DEFAULT_SERVER_PARAMS[k]
    for k in params.keys():
        params_map[k] = params[k]

    status = backend["status"]
    state_val = "WARN"
    summary = "Status: %s" % status

    canonical = status
    if canonical in _DEFAULT_SERVER_PARAMS:
        level = params_map[canonical]
        state_val = _state_from_level(level)
        summary = "Status: %s" % canonical
    else:
        state_val = "WARN"
        summary = "Status: %s" % status

    metrics = {}
    if backend["active"] != None and backend["active"] > 0:
        metrics["active"] = backend["active"]
    if backend["backup"] != None:
        metrics["backup"] = backend["backup"]
    if backend["stot"] != None:
        metrics["stot"] = backend["stot"]

    return {"changed": False, "msg": summary,
            "data": {"state": state_val, "metrics": metrics, "details": summary}}