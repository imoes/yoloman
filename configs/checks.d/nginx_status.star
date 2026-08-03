# ===== check plugin: nginx_status (read-only Starlark translation) =====

# Nginx stub_status parser/check. Reproduces the Checkmk nginx_status check
# against the real on-host nginx stub_status endpoint, without Checkmk.

def _parse_status(stdout):
    # Parse the nginx stub_status body text into a dict of raw counters.
    data = {}
    for line in stdout.splitlines():
        s = line.strip()
        low = s.lower()
        if s.startswith("active connections:"):
            data["active"] = int(s.split(":", 1)[1].strip())
        elif low.startswith("server accepts handled requests"):
            # next line holds the three numbers
            pass
        elif low.startswith("reading:"):
            data["reading"] = int(s.split()[1])
            data["writing"] = int(s.split()[3])
            data["waiting"] = int(s.split()[5])
    return data

def _parse_counts_line(line):
    f = line.split()
    # accepts handled requests
    data = {"accepted": int(f[0]), "handled": int(f[1]), "requests": int(f[2])}
    return data

def _level_state(value, levels, mode):
    # mode: "upper" -> warn if >= warn, crit if >= crit
    #       "lower" -> warn if <= warn, crit if <= crit
    if levels == None:
        return "OK"
    if len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if mode == "upper":
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
    else:
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
    return "OK"

def _hr(value):
    return "%d" % value

def _hr_rate(value):
    return "%f/s" % value

def main(ctx, params):
    if params.get("_discover"):
        # Probe: try each configured port via the stub_status endpoint.
        ports = params.get("ports", [80])
        host = params.get("host", "localhost")
        items = []
        for port in ports:
            url = "http://%s:%s/nginx_status" % (host, port)
            res = ctx.run(["curl", "-fs", url], mutates=False)
            if res.rc != 0 or res.skipped:
                # not reachable / not installed -> no service for this item
                continue
            item = "%s:%s" % (host, port)
            items.append({"item": item, "params": {}, "metrics": [
                "nginx_active", "nginx_reading", "nginx_writing",
                "nginx_waiting", "nginx_accepted", "nginx_handled",
                "nginx_requests",
            ]})
        return {"changed": False, "msg": "discovered %d nginx instances" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    # item is "host:port"
    parts = item.split(":")
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    host = parts[0]
    port = parts[1]
    url = "http://%s:%s/nginx_status" % (host, port)

    res = ctx.run(["curl", "-fs", url], mutates=False)
    if res.rc != 0 or res.skipped or res.stdout == "":
        return {"changed": False, "msg": "nginx status not reachable for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = _parse_status(res.stdout)
    lines = res.stdout.splitlines()
    counts = {}
    for idx, line in enumerate(lines):
        low = line.strip().lower()
        if low.startswith("server accepts handled requests"):
            nxt = lines[idx + 1].strip() if idx + 1 < len(lines) else ""
            counts = _parse_counts_line(nxt)
            break

    if not data and not counts:
        return {"changed": False, "msg": "could not parse nginx status for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data.update(counts)

    active = data.get("active", 0)
    reading = data.get("reading", 0)
    writing = data.get("writing", 0)
    waiting = data.get("waiting", 0)
    accepted = data.get("accepted", 0)
    handled = data.get("handled", 0)
    requests = data.get("requests", 0)

    metrics = {}
    metrics["nginx_active"] = active
    metrics["nginx_reading"] = reading
    metrics["nginx_writing"] = writing
    metrics["nginx_waiting"] = waiting
    metrics["nginx_accepted"] = accepted
    metrics["nginx_handled"] = handled
    metrics["nginx_requests"] = requests

    active_levels = params.get("active_connections")
    active_state = _level_state(active, active_levels, "upper")

    handled_val = handled if handled > 0 else 1
    requests_per_conn = 1.0 * requests / handled_val

    summary = "%s (%d reading, %d writing, %d waiting)" % (
        "Active" + (" " + _hr(active) if active_state == "OK" else " " + _hr(active)),
        reading, writing, waiting)

    # Active connections verdict first
    state = active_state
    msg = "%s connections: %s (%d reading, %d writing, %d waiting)" % (
        "Active", _hr(active), reading, writing, waiting)

    # Accepted / Handled lines are informational OK results
    accepted_msg = "Accepted: %d" % accepted
    handled_msg = "Handled: %d" % handled
    rpc_msg = "Requests: %d (%f/Connection)" % (requests, requests_per_conn)

    details = "%s\n%s\n%s\n%s" % (msg, accepted_msg, handled_msg, rpc_msg)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}