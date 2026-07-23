# ===== Starlark check module for tcp_conn_stats =====
# Read-only: gather TCP connection stats from /proc/net/tcp and /proc/net/tcp6
# Map hex states (e.g., "01" -> ESTABLISHED) or state names from agent output
# Return discovery (single service) and per-state counts with threshold checks

# State mapping from Checkmk's MAP_COUNTER_KEYS (hex -> name)
TCP_STATE_MAP = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECV",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSE",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0A": "LISTEN",
    "0B": "CLOSING",
}

# All expected TCP states (including optional ones like IDLE, BOUND from extended outputs)
ALL_TCP_STATES = [
    "ESTABLISHED",
    "SYN_SENT",
    "SYN_RECV",
    "FIN_WAIT1",
    "FIN_WAIT2",
    "TIME_WAIT",
    "CLOSE",
    "CLOSE_WAIT",
    "LAST_ACK",
    "LISTEN",
    "CLOSING",
    # Extended states occasionally seen
    "IDLE",
    "BOUND",
]

def _count_values(d):
    total = 0
    for v in d.values():
        total = total + v
    return total

def _parse_tcp_conn_stats(ctx):
    # Gather stats from /proc/net/tcp and /proc/net/tcp6
    stats = {}
    for state in ALL_TCP_STATES:
        stats[state] = 0
    
    # Read both tcp and tcp6 files (both must exist on typical Linux)
    for proc_file in ["/proc/net/tcp", "/proc/net/tcp6"]:
        if ctx.file_exists(proc_file):
            content = ctx.file_read(proc_file)
            for line in content.splitlines()[1:]:  # skip header
                parts = line.split()
                if len(parts) < 4:
                    continue
                state_hex = parts[3].split(":")[0]  # state field is like "0A:..."
                if state_hex in TCP_STATE_MAP:
                    state_name = TCP_STATE_MAP[state_hex]
                    stats[state_name] = stats[state_name] + 1
                elif len(state_hex) == 2:
                    # Unknown hex state — skip (Checkmk also skips on KeyError)
                    pass
    
    return stats

def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        stats = _parse_tcp_conn_stats(ctx)
        total = _count_values(stats)
        # Only discover service if any non-zero counts exist (like Checkmk's discover_tcp_connections)
        if total > 0:
            return {
                "changed": False,
                "msg": "discovered TCP connection service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ALL_TCP_STATES}
                ]},
            }
        else:
            return {
                "changed": False,
                "msg": "no TCP connections found",
                "data": {"discovery": []},
            }

    # === CHECK MODE ===
    # Gather fresh stats (since check runs for single item "", we recompute)
    stats = _parse_tcp_conn_stats(ctx)
    
    # Prepare result details and state evaluation per state
    details_parts = []
    state_overall = "OK"
    metrics = {}
    
    for state_name in ALL_TCP_STATES:
        count = stats.get(state_name, 0)
        warn_val = params.get(state_name)
        crit_val = params.get(state_name + "_crit")
        
        # Map to Checkmk behavior: if warn/crit are set, evaluate upper thresholds
        if crit_val != None and count >= int(crit_val):
            state_this = "CRIT"
        elif warn_val != None and count >= int(warn_val):
            state_this = "WARN"
        else:
            state_this = "OK"
        
        # Overall state priority: CRIT > WARN > OK
        if state_this == "CRIT" and state_overall != "CRIT":
            state_overall = "CRIT"
        elif state_this == "WARN" and state_overall == "OK":
            state_overall = "WARN"
        
        # Record metric and label
        metrics[state_name] = count
        label = state_name.replace("_", " ").capitalize()
        details_parts.append("%s: %d" % (label, count))
    
    # Build Checkmk-style message
    msg = ", ".join(details_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_overall,
            "metrics": metrics,
            "details": "",
        },
    }