# Checkmk check: tcp_conn_stats -> read-only Starlark check module
# Single-service check. Gathers TCP connection state counts from
# /proc/net/tcp and /proc/net/tcp6 and grades them against per-state
# thresholds supplied via params.

# Mapping of hex state codes (as strings) -> TCP state label, mirroring
# Checkmk's MAP_COUNTER_KEYS for the tcp_conn_stats check.
_HEX_STATE_MAP = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECV",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSED",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0A": "CLOSING",
    "0B": "LISTEN",
    "0C": "BOUND",
}

# Empty-stats template: all known states default to 0.
def _empty_stats():
    return {
        "CLOSED": 0,
        "CLOSE_WAIT": 0,
        "CLOSING": 0,
        "ESTABLISHED": 0,
        "FIN_WAIT1": 0,
        "FIN_WAIT2": 0,
        "IDLE": 0,
        "LAST_ACK": 0,
        "LISTEN": 0,
        "SYN_RECV": 0,
        "SYN_SENT": 0,
        "TIME_WAIT": 0,
        "BOUND": 0,
    }

def _read_tcp_states(ctx):
    """Read /proc/net/tcp and /proc/net/tcp6 and tally state counts.
    Returns (stats_dict, total_connections)."""
    stats = _empty_stats()
    total = 0
    for path in ["/proc/net/tcp", "/proc/net/tcp6"]:
        if not ctx.file_exists(path):
            continue
        content = ctx.file_read(path)
        for line in content.splitlines():
            fields = line.split()
            if len(fields) < 4:
                continue
            # Skip header lines (first entry per file starts with "sl").
            if fields[0] == "sl":
                continue
            # The state code is the 4th column, e.g. "0A".
            state_code = fields[3]
            label = _HEX_STATE_MAP.get(state_code)
            if label == None:
                continue
            stats[label] = stats[label] + 1
            total = total + 1
    return stats, total

def _grade(value, levels):
    """Grade a single value against upper levels (warn, crit).
    Returns "OK", "WARN" or "CRIT". None levels -> OK."""
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(a, 0) >= order.get(b, 0):
        return a
    return b

def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        stats, total = _read_tcp_states(ctx)
        if total == 0:
            return {"changed": False, "msg": "no TCP connections found",
                    "data": {"discovery": []}}
        metrics = []
        for name in sorted(stats.keys()):
            if stats[name] != 0:
                metrics.append(name)
        return {"changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": metrics}
                ]}}

    # --- CHECK MODE (single service, item ignored) ---
    stats, total = _read_tcp_states(ctx)
    if total == 0:
        return {"changed": False,
                "msg": "no TCP connections found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_lines = []
    overall = "OK"
    for name in sorted(stats.keys()):
        count = stats[name]
        metrics[name] = count
        label = name.replace("_", " ").capitalize()
        details_lines.append("%s: %d" % (label, count))
        levels = params.get(name)
        overall = _worst(overall, _grade(count, levels))

    details = "\n".join(details_lines)
    msg = "Total TCP connections: %d" % total
    if overall == "OK":
        msg = msg + " (states OK)"
    return {"changed": False, "msg": msg,
            "data": {"state": overall, "metrics": metrics, "details": details}}