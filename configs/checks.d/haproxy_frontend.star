# Module: haproxy_frontend
# FQCN: checkmk.haproxy_frontend
# Short description: HAProxy Frontend %s
# Reads the on-host HAProxy stats CSV (via the stats socket or HTTP endpoint)
# and reproduces the Checkmk haproxy_frontend check: discovery of frontend
# items, status-level grading (OPEN=OK, STOP=CRIT), and session-total metric.

HAProxyFrontendStatus = {
    "OPEN": "OPEN",
    "STOP": "STOP",
}

DEFAULT_FRONTEND_STATES = {
    "OPEN": 0,
    "STOP": 2,
}

STATUS_COL = 17
STOT_COL = 7
TYPE_COL = 32


def _get_stats(ctx, params):
    """Gather HAProxy frontend stats.

    Tries the local HAProxy stats socket first (default /var/run/haproxy.sock),
    then the stats socket path param, then a CSV stats endpoint.
    Returns a list of rows (each a list of string fields), or None on failure.
    """
    socket_path = params.get("socket_path", "/var/run/haproxy.sock")
    csv_url = params.get("csv_url")

    if ctx.file_exists(socket_path):
        res = ctx.run(
            ["echo", "show stat", "|", "socat", "UNIX-LISTEN:" + socket_path, "-"],
            mutates=False,
            ok_codes=[0],
        )
        if res.rc == 0 and res.stdout:
            lines = res.stdout.strip().splitlines()
            rows = []
            for line in lines:
                fields = line.split(",")
                if len(fields) > 32:
                    rows.append(fields)
            return rows
        return None

    if csv_url:
        res = ctx.run(["curl", "-s", csv_url], mutates=False, ok_codes=[0])
        if res.rc == 0 and res.stdout:
            lines = res.stdout.strip().splitlines()
            rows = []
            for line in lines:
                fields = line.split(",")
                if len(fields) > 32:
                    rows.append(fields)
            return rows
        return None

    return None


def _parse_frontend(rows):
    """Extract frontend entries from raw stats rows."""
    frontends = {}
    for fields in rows:
        if len(fields) <= 32:
            continue
        if fields[TYPE_COL] != "0":
            continue
        name = fields[0]
        status = fields[STATUS_COL]
        stot_raw = fields[STOT_COL]
        stot = None
        if stot_raw.strip().isdigit():
            stot = int(stot_raw)
        frontends[name] = {"status": status, "stot": stot}
    return frontends


def _grade_status(status_str, states):
    """Grade a frontend status string against the states dict."""
    if status_str not in HAProxyFrontendStatus:
        return 3
    level = states.get(status_str)
    if level == 0:
        return 0
    if level == 1:
        return 1
    if level == 2:
        return 2
    return 3


def main(ctx, params):
    if params.get("_discover"):
        rows = _get_stats(ctx, params)
        if rows == None:
            return {
                "changed": False,
                "msg": "no HAProxy frontend data available",
                "data": {"discovery": []},
            }

        frontends = _parse_frontend(rows)
        discovery = []
        for name, data in frontends.items():
            discovery.append({
                "item": name,
                "params": dict(DEFAULT_FRONTEND_STATES),
                "metrics": ["session_rate"],
            })

        return {
            "changed": False,
            "msg": "discovered %d frontends" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    rows = _get_stats(ctx, params)
    if rows == None:
        return {
            "changed": False,
            "msg": "HAProxy not reachable for frontend " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    frontends = _parse_frontend(rows)
    data = frontends.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "frontend " + str(item) + " not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    status_str = data["status"]
    states = params.get("states", DEFAULT_FRONTEND_STATES)
    level = _grade_status(status_str, states)

    if level == 0:
        state = "OK"
    elif level == 1:
        state = "WARN"
    elif level == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    metrics = {}
    stot = data["stot"]
    if stot != None:
        metrics["session_rate"] = stot

    summary = "Status: " + status_str + ", Stot: " + str(stot)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }