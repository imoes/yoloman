# Checkmk netstat check -> Starlark module (read-only, no mutations)
# Discover: never (enforced only), check: count connections matching params

STATE_TRANSLATIONS = {
    "LISTEN": "LISTENING",
    "ESTAB": "ESTABLISHED",
    "FIN-WAIT-1": "FIN-WAIT1",
    "FIN-WAIT-2": "FIN-WAIT2",
}

# Predefine ConnectionState enum names as strings (no StrEnum in Starlark)
CONNECTION_STATES = [
    "ESTABLISHED", "LISTENING", "SYN_SENT", "SYN_RECV", "LAST_ACK",
    "CLOSE_WAIT", "TIME_WAIT", "CLOSED", "CLOSING", "FIN_WAIT1",
    "FIN_WAIT2", "BOUND", "UNDEFINED"
]

def _translate_state(state):
    s = STATE_TRANSLATIONS.get(state, state)
    # Replace "-" with "_" (ss format)
    s = s.replace("-", "_")
    return s

def _split_ip_address(ip):
    if ":" in ip:
        parts = ip.rsplit(":", 1)
    else:
        # IPv4 with dots might be in format "a.b.c.d.port" (AIX-like), try dot split
        parts = ip.rsplit(".", 1)
    if len(parts) == 2:
        return {"ip_address": parts[0], "port": parts[1]}
    # Fallback: treat whole string as IP, port as empty
    return {"ip_address": ip, "port": ""}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: never (enforced only) - return empty list
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # Check mode
    item = params.get("item", "")

    # Gather netstat data via ss (modern replacement for netstat)
    # ss -tuln gives TCP/UDP listening ports, ss -tun shows all connections
    # Use ss -tunp or ss -tun to get all connections (no -p to avoid root requirement)
    # ss -tuln only shows listening; for full picture use ss -tun
    # Try both ss and netstat fallback
    res = ctx.run(["ss", "-tun"], mutates=False)
    if res.rc != 0 or not res.stdout:
        # Fallback to netstat if ss not available
        res = ctx.run(["netstat", "-tun"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "failed to gather connection data",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": "no connection data available"}}

    connections = []
    lines = res.stdout.splitlines()
    # ss output: State Recv-Q Send-Q Local Address:Port Peer Address:Port
    # netstat output: Proto Recv-Q Send-Q Local Address Foreign Address State
    # Detect format: ss has "State" header, netstat doesn't
    for line in lines[1:]:
        fields = line.split()
        if len(fields) == 0:
            continue
        proto = ""
        local = ""
        remote = ""
        connstate = ""
        # ss format: first field is State (e.g., "tcp", "udp", "State"), then Recv-Q, Send-Q, Local, Remote
        # netstat format: Proto, Recv-Q, Send-Q, Local, Foreign, State
        if len(fields) >= 6 and fields[0] in ["tcp", "udp", "tcp6", "udp6"]:
            # ss format: State, Recv-Q, Send-Q, Local, Remote
            proto = fields[0]
            local = fields[3]
            remote = fields[4]
            connstate = fields[0].upper() if fields[0] in ["tcp", "udp", "tcp6", "udp6"] else ""
        elif len(fields) == 6:
            # netstat format
            proto = fields[0]
            local = fields[3]
            remote = fields[4]
            connstate = fields[5]
        elif len(fields) >= 5 and fields[0] in ["tcp", "udp", "tcp6", "udp6"]:
            # ss without -p, may have fewer fields
            proto = fields[0]
            local = fields[3]
            remote = fields[4]
            connstate = "ESTABLISHED"  # default for non-listening ss lines
        else:
            continue

        if proto.startswith("tcp"):
            proto = "TCP"
        elif proto.startswith("udp"):
            proto = "UDP"
            connstate = "LISTENING"

        if connstate == "":
            continue

        # Translate state
        connstate = _translate_state(connstate)

        # Validate state
        if connstate not in CONNECTION_STATES:
            continue

        connections.append({
            "proto": proto,
            "local_address": _split_ip_address(local),
            "remote_address": _split_ip_address(remote),
            "state": connstate
        })

    # Count matches
    count = 0
    for conn in connections:
        # Check each param; defaults are empty (match any)
        match = True
        for key, default_val in [
            ("local_ip", None),
            ("local_port", None),
            ("remote_ip", None),
            ("remote_port", None),
            ("proto", None),
            ("state", None)
        ]:
            val = params.get(key)
            if val != None:
                # Compare with connection value
                if key == "local_ip" and str(val) != conn["local_address"]["ip_address"]:
                    match = False
                elif key == "local_port" and str(val) != conn["local_address"]["port"]:
                    match = False
                elif key == "remote_ip" and str(val) != conn["remote_address"]["ip_address"]:
                    match = False
                elif key == "remote_port" and str(val) != conn["remote_address"]["port"]:
                    match = False
                elif key == "proto" and str(val) != conn["proto"]:
                    match = False
                elif key == "state" and str(val) != conn["state"]:
                    match = False
                if not match:
                    break
        if match:
            count += 1

    # Thresholds
    max_states = params.get("max_states")
    min_states = params.get("min_states")

    # Parse thresholds: Checkmk format ("no_levels", None) or (warn, crit)
    max_warn = None
    max_crit = None
    min_warn = None
    min_crit = None

    if max_states != None and type(max_states) == "list" and len(max_states) == 2:
        if max_states[0] != "no_levels":
            max_warn = max_states[0]
            max_crit = max_states[1]
    if min_states != None and type(min_states) == "list" and len(min_states) == 2:
        if min_states[0] != "no_levels":
            min_warn = min_states[0]
            min_crit = min_states[1]

    # Determine state
    state = "OK"
    details = ""

    # Upper levels (max_states)
    if max_warn != None and count >= max_warn:
        state = "WARN"
        details = "max connections exceeded"
        if max_crit != None and count >= max_crit:
            state = "CRIT"
            details = "max connections critically exceeded"

    # Lower levels (min_states)
    if min_warn != None and count <= min_warn:
        if state == "OK":
            state = "WARN"
            details = "min connections not reached"
        elif state == "WARN" and count <= min_warn:
            details = "min connections not reached; max connections exceeded"
        if min_crit != None and count <= min_crit:
            state = "CRIT"
            if max_warn != None and count >= max_warn:
                details = "min and max connections both out of range"
            else:
                details = "min connections critically not reached"

    # Build message
    msg = "Connections: %d" % count
    if details != "":
        msg = msg + " (%s)" % details

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"connections": count},
                     "details": details}}