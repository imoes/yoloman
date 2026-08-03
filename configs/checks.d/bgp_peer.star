# Checkmk check: bgp_peer -> read-only Starlark check module (SNMP)

DEFAULT_ADMIN_STATE_MAPPING = {
    "halted": 0,
    "running": 0,
}

DEFAULT_PEER_STATE_MAPPING = {
    "idle": 0,
    "connect": 0,
    "active": 0,
    "opensent": 0,
    "openconfirm": 0,
    "established": 0,
}

ADMIN_STATE_MAPPING = {
    "1": "halted",
    "2": "running",
}

PEER_STATE_MAPPING = {
    "1": "idle",
    "2": "connect",
    "3": "active",
    "4": "opensent",
    "5": "openconfirm",
    "6": "established",
}

BGP_ERROR_CODE_NAME_MAPPING = {
    0: "No Error",
    1: "Message Header Error",
    2: "OPEN Message Error",
    3: "UPDATE Message Error",
    4: "Hold Timer Expired",
    5: "Finite State Machine Error",
    6: "Cease",
    7: "ROUTE-REFRESH Message Error",
    8: "Send Hold Timer Expired",
    9: "Loss of LSDB Synchronization",
}


def _safe_int(value):
    if value == None:
        return 0
    s = str(value)
    if not s.isdigit():
        return 0
    return int(s)


def _render_timespan(seconds):
    secs = _safe_int(seconds)
    if secs < 0:
        secs = 0
    days = secs // 86400
    hours = (secs % 86400) // 3600
    minutes = (secs % 3600) // 60
    seconds = secs % 60
    if days > 0:
        return "%dd %dh %dm" % (days, hours, minutes)
    if hours > 0:
        return "%dh %dm %ds" % (hours, minutes, seconds)
    if minutes > 0:
        return "%dm %ds" % (minutes, seconds)
    return "%ds" % seconds


def _extract_remote_addr(oid):
    elems = oid.split(".")
    if len(elems) > 0 and elems[0] == "":
        elems = elems[1:]
    if len(elems) >= 4:
        last4 = elems[-4:]
        ok = True
        for e in last4:
            if not e.isdigit():
                ok = False
                break
            v = int(e)
            if v < 0 or v > 255:
                ok = False
                break
        if ok:
            return ".".join(last4)
    return ".".join(elems[-4:]) if len(elems) >= 4 else ""


def _snmpwalk_rows(ctx, params, column_oid):
    """Walk one SNMP column; return dict index_oid -> value string."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    args = ["snmpwalk", "-v", version, "-c", community, "-On"]
    if version == "3":
        username = params.get("username")
        authproto = params.get("authproto")
        authpass = params.get("authpass")
        privproto = params.get("privproto")
        privpass = params.get("privpass")
        if username != None:
            args = args + ["-u", username]
            if authproto != None and authpass != None:
                args = args + ["-a", authproto, "-A", authpass]
            if privproto != None and privpass != None:
                args = args + ["-x", privproto, "-X", privpass]
    args = args + [host, column_oid]
    res = ctx.run(args, mutates=False)
    rows = {}
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        if line == "":
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        rows[oid] = value
    return rows


def _snmpget(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    args = ["snmpget", "-v", version, "-c", community]
    if version == "3":
        username = params.get("username")
        authproto = params.get("authproto")
        authpass = params.get("authpass")
        privproto = params.get("privproto")
        privpass = params.get("privpass")
        if username != None:
            args = args + ["-u", username]
            if authproto != None and authpass != None:
                args = args + ["-a", authproto, "-A", authpass]
            if privproto != None and privpass != None:
                args = args + ["-x", privproto, "-X", privpass]
    args = args + ["-Oqv", host, oid]
    return ctx.run(args, mutates=False)


def _build_peers(ctx, params, rows_by_col, col_specs_prefix):
    """Correlate walked columns by their numeric index OID suffix."""
    peers = {}
    first = rows_by_col[0]
    for idx_oid in first:
        vals = []
        for cd in rows_by_col:
            vals.append(cd.get(idx_oid))
        remote_addr = _extract_remote_addr(idx_oid)
        peer = _make_peer(vals, col_specs_prefix, idx_oid)
        peers[remote_addr] = peer
    return peers


def _make_peer(vals, col_specs, idx_oid):
    if col_specs == "ietf":
        # IETF rows already carry local_identifier in vals; handled separately
        return _peer_generic(vals, idx_oid)
    return _peer_generic(vals, idx_oid)


def _peer_generic(vals, idx_oid):
    remote_addr = _extract_remote_addr(idx_oid)
    remote_as = _safe_int(vals[2]) if len(vals) > 2 else 0
    admin_raw = vals[4] if len(vals) > 4 else "0"
    state_raw = vals[5] if len(vals) > 5 else "0"
    admin_state = ADMIN_STATE_MAPPING.get(admin_raw, "unknown")
    peer_state = PEER_STATE_MAPPING.get(state_raw, "unknown")
    established = _safe_int(vals[7]) if len(vals) > 7 else 0
    description = vals[8] if len(vals) > 8 else ""
    last_error_text = vals[6] if len(vals) > 6 else ""
    local_address = vals[0] if len(vals) > 0 and vals[0] != None else ""
    local_identifier = vals[1] if len(vals) > 1 and vals[1] != None else ""
    remote_identifier = vals[3] if len(vals) > 3 and vals[3] != None else ""
    return {
        "remote_addr": remote_addr,
        "local_address": local_address,
        "local_identifier": local_identifier,
        "remote_as": remote_as,
        "remote_identifier": remote_identifier,
        "admin_state": admin_state,
        "peer_state": peer_state,
        "established_time": established,
        "description": description,
        "last_error_text": last_error_text,
    }


def _gather_peers(ctx, params):
    # Probe for existence: is there a device at all?
    sysd = _snmpget(ctx, params, ".1.3.6.1.2.1.1.1.0")
    if sysd.rc == 127:
        return {}
    if sysd.rc != 0:
        return {}
    vendor_hint = ""
    if sysd.stdout.find("Arista") >= 0:
        vendor_hint = "arista"
    elif sysd.stdout.find("Cisco") >= 0:
        vendor_hint = "cisco"

    peers = {}

    if vendor_hint == "arista":
        base = ".1.3.6.1.4.1.30065.4.1.1"
        cols = ["2.1.3", "2.1.8", "2.1.10", "2.1.11", "2.1.12", "2.1.13",
                "3.1.4", "4.1.1", "2.1.14"]
        rows_by_col = []
        for c in cols:
            rows_by_col.append(_snmpwalk_rows(ctx, params, base + "." + c))
        peer_dicts = _build_peers(ctx, params, rows_by_col, "arista")
        peers = peer_dicts
    elif vendor_hint == "cisco":
        base = ".1.3.6.1.4.1.9.9.187.1.2.5.1"
        cols = ["6", "9", "11", "12", "4", "3", "28", "19"]
        rows_by_col = []
        for c in cols:
            rows_by_col.append(_snmpwalk_rows(ctx, params, base + "." + c))
        peer_dicts = _build_peers(ctx, params, rows_by_col, "cisco")
        if len(peer_dicts) == 0:
            base = ".1.3.6.1.4.1.9.9.187.1.2.9.1"
            cols = ["8", "11", "13", "14", "6", "5", "30", "21"]
            rows_by_col = []
            for c in cols:
                rows_by_col.append(_snmpwalk_rows(ctx, params, base + "." + c))
            peer_dicts = _build_peers(ctx, params, rows_by_col, "cisco")
        peers = peer_dicts
    else:
        # IETF BGP4-MIB
        probe = _snmpget(ctx, params, ".1.3.6.1.2.1.15.1.0")
        if probe.rc != 0:
            return {}
        base = ".1.3.6.1.2.1.15.3.1"
        cols = ["5", "9", "1", "3", "2", "14", "16", "7"]
        rows_by_col = []
        for c in cols:
            rows_by_col.append(_snmpwalk_rows(ctx, params, base + "." + c))
        ident_res = _snmpget(ctx, params, ".1.3.6.1.2.1.15.4.0")
        local_identifier = ""
        if ident_res.rc == 0:
            local_identifier = ident_res.stdout.strip()
        if len(rows_by_col[0]) == 0:
            return {}
        first_rows = rows_by_col[0]
        peer_rows = {}
        for idx_oid in first_rows:
            vals = []
            for cd in rows_by_col:
                vals.append(cd.get(idx_oid))
            vals.append(local_identifier)
            peer_rows[idx_oid] = vals
        peers = {}
        for idx_oid, vals in peer_rows.items():
            remote_addr = _extract_remote_addr(idx_oid)
            peers[remote_addr] = _peer_generic_idx(vals, idx_oid)

    return peers


def _peer_generic_idx(vals, idx_oid):
    """Peer builder used for IETF rows where local_identifier was grafted
    at the end of vals (index len-1)."""
    remote_addr = _extract_remote_addr(idx_oid)
    # IETF column order after graft: LocalAddr(0), RemoteAs(1), Identifier(2),
    # AdminStatus(3), State(4), LastError(5), FsmEstablishedTime(6),
    # RemoteAddr is from OID. local_identifier appended at end.
    local_identifier = vals[-1] if len(vals) > 0 else ""
    # Remove the grafted identifier for the generic-shaping indices.
    core = vals[:8] if len(vals) >= 8 else vals
    # core indices: 0 LocalAddr, 1 RemoteAs, 2 Identifier, 3 AdminStatus,
    # 4 State, 5 LastError, 6 FsmEstablished, 7 RemoteAddr(OID)
    remote_as = _safe_int(core[1]) if len(core) > 1 else 0
    admin_raw = core[3] if len(core) > 3 else "0"
    state_raw = core[4] if len(core) > 4 else "0"
    admin_state = ADMIN_STATE_MAPPING.get(admin_raw, "unknown")
    peer_state = PEER_STATE_MAPPING.get(state_raw, "unknown")
    established = _safe_int(core[6]) if len(core) > 6 else 0
    last_error_text = core[5] if len(core) > 5 else ""
    local_address = core[0] if len(core) > 0 and core[0] != None else ""
    remote_identifier = core[2] if len(core) > 2 and core[2] != None else ""
    return {
        "remote_addr": remote_addr,
        "local_address": local_address,
        "local_identifier": local_identifier,
        "remote_as": remote_as,
        "remote_identifier": remote_identifier,
        "admin_state": admin_state,
        "peer_state": peer_state,
        "established_time": established,
        "description": "",
        "last_error_text": last_error_text,
    }


def main(ctx, params):
    if params.get("_discover"):
        peers = _gather_peers(ctx, params)
        discovery = []
        for addr, peer in peers.items():
            discovery.append({
                "item": addr,
                "params": {
                    "admin_state_mapping": params.get("admin_state_mapping", DEFAULT_ADMIN_STATE_MAPPING),
                    "peer_state_mapping": params.get("peer_state_mapping", DEFAULT_PEER_STATE_MAPPING),
                },
                "metrics": ["uptime"],
                "service_labels": {
                    "cmk/bgp/description": peer.get("description", ""),
                },
            })
        return {
            "changed": False,
            "msg": "discovered %d BGP peers" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no BGP peer item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    peers = _gather_peers(ctx, params)
    peer = peers.get(item)
    if peer == None:
        return {
            "changed": False,
            "msg": "no such BGP peer: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    admin_mapping = params.get("admin_state_mapping", DEFAULT_ADMIN_STATE_MAPPING)
    peer_mapping = params.get("peer_state_mapping", DEFAULT_PEER_STATE_MAPPING)

    admin_level = admin_mapping.get(peer["admin_state"], 3)
    peer_level = peer_mapping.get(peer["peer_state"], 3)

    if admin_level == 3 or peer_level == 3:
        state = "CRIT"
    elif admin_level == 0 and peer_level == 0:
        state = "OK"
    else:
        state = "WARN"

    summaries = [
        "Description: %s" % peer.get("description", ""),
        "Local address: %s" % peer.get("local_address", ""),
        "Admin state: %s" % peer.get("admin_state", ""),
        "Peer state: %s" % peer.get("peer_state", ""),
        "Established time: %s" % _render_timespan(peer.get("established_time", 0)),
    ]
    detail_lines = [
        "Local identifier: %s" % peer.get("local_identifier", ""),
        "Remote identifier: %s" % peer.get("remote_identifier", ""),
        "Remote AS number: %s" % peer.get("remote_as", 0),
        "Remote address: %s" % item,
        "Last received error: %s" % peer.get("last_error_text", ""),
    ]

    metrics = {"uptime": peer.get("established_time", 0)}
    details = "\n".join(detail_lines)

    return {
        "changed": False,
        "msg": " | ".join(summaries),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }