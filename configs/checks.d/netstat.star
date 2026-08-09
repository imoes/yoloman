def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "discovery never yields items for this check",
                "data": {"discovery": []}}

    item = params.get("item", "")
    warn = params.get("warn")
    crit = params.get("crit")

    # Probe for the real data source
    netstat_res = ctx.run(["netstat", "-an"], mutates=False)
    ss_res = ctx.run(["ss", "-tan"], mutates=False)
    have_netstat = netstat_res.rc == 0
    have_ss = ss_res.rc == 0
    if not have_netstat and not have_ss:
        return {"changed": False, "msg": "neither netstat nor ss available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    connections = _parse_connections(have_netstat, netstat_res.stdout,
                                     have_ss, ss_res.stdout)

    proto_filter = params.get("proto")
    state_filter = params.get("state")
    local_ip_filter = params.get("local_ip")
    local_port_filter = params.get("local_port")
    remote_ip_filter = params.get("remote_ip")
    remote_port_filter = params.get("remote_port")

    count = 0
    for c in connections:
        if proto_filter != None and c["proto"] != proto_filter:
            continue
        if state_filter != None and c["state"] != state_filter:
            continue
        if local_ip_filter != None and c["local_ip"] != local_ip_filter:
            continue
        if local_port_filter != None and c["local_port"] != local_port_filter:
            continue
        if remote_ip_filter != None and c["remote_ip"] != remote_ip_filter:
            continue
        if remote_port_filter != None and c["remote_port"] != remote_port_filter:
            continue
        count += 1

    state = _grade(count, warn, crit)
    return {"changed": False, "msg": "Connections matching: %d" % count,
            "data": {"state": state, "metrics": {"connections": count}, "details": ""}}


def _parse_connections(have_netstat, netstat_out, have_ss, ss_out):
    conns = []
    if have_netstat:
        for line in netstat_out.splitlines():
            parts = line.split()
            if len(parts) < 6:
                continue
            proto = parts[0]
            local = parts[3]
            remote = parts[4]
            connstate = parts[5]
            conn = _build_connection(proto, local, remote, connstate)
            if conn != None:
                conns.append(conn)
    if have_ss:
        for line in ss_out.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 5:
                continue
            proto = parts[0]
            state_field = parts[1]
            local = parts[4]
            remote = parts[5] if len(parts) > 5 else "0.0.0.0:*"
            conn = _build_connection(proto, local, remote, state_field)
            if conn != None:
                conns.append(conn)
    return conns


def _build_connection(proto, local, remote, connstate):
    if proto.startswith("tcp"):
        p = "TCP"
    elif proto.startswith("udp"):
        p = "UDP"
        connstate = "LISTENING"
    else:
        return None
    connstate = STATE_TRANSLATIONS.get(connstate, connstate)
    connstate = connstate.replace("-", "_")
    local_ip, local_port = _split_ip(local)
    remote_ip, remote_port = _split_ip(remote)
    return {"proto": p, "local_ip": local_ip, "local_port": local_port,
            "remote_ip": remote_ip, "remote_port": remote_port, "state": connstate}


def _split_ip(addr):
    if ":" in addr and not addr.startswith("*"):
        parts = addr.rsplit(":", 1)
    else:
        parts = addr.rsplit(".", 1)
    return (parts[0], parts[1] if len(parts) > 1 else "")


def _grade(count, warn, crit):
    if crit != None and count >= crit:
        return "CRIT"
    if warn != None and count >= warn:
        return "WARN"
    return "OK"


STATE_TRANSLATIONS = {
    "LISTEN": "LISTENING",
    "ESTAB": "ESTABLISHED",
    "FIN-WAIT-1": "FIN_WAIT1",
    "FIN-WAIT-2": "FIN_WAIT2",
}