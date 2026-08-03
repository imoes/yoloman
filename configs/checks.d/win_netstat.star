def main(ctx, params):
    if params.get("_discover"):
        # discover_netstat_never yields nothing — this check is enforced only.
        # No services are auto-discovered; operators must create them manually.
        return {
            "changed": False,
            "msg": "discovered 0 items (enforced check, no auto-discovery)",
            "data": {"discovery": []},
        }

    # Check mode: count connections matching the given parameters.
    item = params.get("item", "")
    # Parameters that define which connections to match
    local_ip = params.get("local_ip", None)
    local_port = params.get("local_port", None)
    remote_ip = params.get("remote_ip", None)
    remote_port = params.get("remote_ip", None)
    proto = params.get("proto", None)
    conn_state = params.get("state", None)

    # Thresholds
    min_states = params.get("min_states", ("no_levels", None))
    max_states = params.get("max_states", ("no_levels", None))

    # Gather connection data using Linux netstat (equivalent to Windows netstat output)
    res = ctx.run(["netstat", "-an"], mutates=False)
    if res.rc != 0:
        if res.rc == 127:
            return {
                "changed": False,
                "msg": "netstat not found on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        return {
            "changed": False,
            "msg": "failed to run netstat: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse netstat -an output and count matching connections
    connections = []
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        if parts[0] == "Proto":
            continue  # header
        if parts[0] in ("tcp", "tcp6", "udp", "udp6"):
            connections.append(_parse_netstat_line(parts))

    # Count matching connections
    count = _count_matching(connections, local_ip, local_port, remote_ip, remote_port, proto, conn_state)

    # Apply threshold logic
    state = "OK"
    warn_msg = ""

    # max_states: WARN if value >= warn, CRIT if value >= crit (upper levels)
    if max_states[0] != "no_levels" and max_states[1] != None:
        warn_level, crit_level = max_states[1]
        if count >= crit_level:
            state = "CRIT"
        elif count >= warn_level:
            state = "WARN"

    # min_states: WARN if value <= warn, CRIT if value <= crit (lower levels)
    if min_states[0] != "no_levels" and min_states[1] != None:
        warn_level, crit_level = min_states[1]
        if count <= crit_level:
            state = "CRIT"
        elif count <= warn_level:
            state = "WARN"

    msg = "Matching connections: %d" % count
    if state != "OK":
        msg = msg + " (state: " + state + ")"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"connections": count}, "details": ""},
    }


def _parse_netstat_line(parts):
    """Parse a single netstat -an line into a connection dict."""
    proto = parts[0]
    local = parts[3] if proto in ("tcp", "tcp6") else parts[2] if proto in ("udp", "udp6") else parts[2]
    remote = parts[4] if proto in ("tcp", "tcp6") else parts[3] if proto in ("udp", "udp6") else "*"
    state = ""

    if proto in ("tcp", "tcp6"):
        # tcp lines: Proto Recv-Q Send-Q Local Address Foreign Address State
        state = parts[5] if len(parts) > 5 else ""
        local_addr, local_p = _split_ip(local)
        remote_addr, remote_p = _split_ip(remote)
    elif proto in ("udp", "udp6"):
        # udp lines: Proto Recv-Q Send-Q Local Address Foreign Address
        local_addr, local_p = _split_ip(local)
        remote_addr = "*"
        remote_p = "*"
        state = "LISTENING"
    else:
        local_addr = local
        local_p = "*"
        remote_addr = remote
        remote_p = "*"
        state = ""

    # Normalize protocol
    if proto.startswith("tcp"):
        proto_norm = "TCP"
    elif proto.startswith("udp"):
        proto_norm = "UDP"
    else:
        proto_norm = proto

    # Normalize state names to match ConnectionState enum
    state_norm = _normalize_state(state)

    return {
        "proto": proto_norm,
        "local_ip": local_addr,
        "local_port": local_p,
        "remote_ip": remote_addr,
        "remote_port": remote_p,
        "state": state_norm,
    }


def _split_ip(addr):
    """Split an IP:port address, handling IPv6."""
    if addr.startswith("*"):
        return ("*", "*")
    if addr.startswith("["):
        # IPv6 format [::1]:port
        bracket_end = addr.find("]")
        if bracket_end > 0:
            ip = addr[1:bracket_end]
            port_part = addr[bracket_end + 1:]
            if port_part.startswith(":"):
                return (ip, port_part[1:])
            return (ip, "*")
    # Try splitting on last colon for IPv4 or IPv6 without brackets
    if ":" in addr:
        parts = addr.rsplit(":", 1)
        return (parts[0], parts[1])
    # No port
    return (addr, "*")


def _normalize_state(state):
    """Normalize netstat state names to ConnectionState enum values."""
    state_map = {
        "ESTABLISHED": "ESTABLISHED",
        "LISTEN": "LISTENING",
        "LISTENING": "LISTENING",
        "SYN_SENT": "SYN_SENT",
        "SYN_RECV": "SYN_RECV",
        "LAST_ACK": "LAST_ACK",
        "CLOSE_WAIT": "CLOSE_WAIT",
        "TIME_WAIT": "TIME_WAIT",
        "TIMED_WAIT": "TIME_WAIT",
        "CLOSED": "CLOSED",
        "CLOSING": "CLOSING",
        "FIN_WAIT1": "FIN_WAIT1",
        "FIN_WAIT2": "FIN_WAIT2",
        "FIN_WAIT_1": "FIN_WAIT1",
        "FIN_WAIT_2": "FIN_WAIT2",
        "": "LISTENING",  # UDP has no state
    }
    return state_map.get(state, state)


def _count_matching(connections, local_ip, local_port, remote_ip, remote_port, proto, conn_state):
    """Count connections matching all given (non-None) parameters."""
    count = 0
    for conn in connections:
        if local_ip != None and str(conn["local_ip"]) != str(local_ip):
            continue
        if local_port != None and str(conn["local_port"]) != str(local_port):
            continue
        if remote_ip != None and str(conn["remote_ip"]) != str(remote_ip):
            continue
        if remote_port != None and str(conn["remote_port"]) != str(remote_port):
            continue
        if proto != None and str(conn["proto"]) != str(proto):
            continue
        if conn_state != None and str(conn["state"]) != str(conn_state):
            continue
        count += 1
    return count