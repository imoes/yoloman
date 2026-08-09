# ===== netscaler_vserver — Checkmk SNMP check, read-only Starlark =====

NETSCALER_STATES = {
    "0": [1, "unknown"],
    "1": [2, "down"],
    "2": [1, "unknown"],
    "3": [1, "busy"],
    "4": [1, "out of service"],
    "5": [1, "transition to out of service"],
    "7": [0, "up"],
}

NETSCALER_TYPES = {
    "0": "http",
    "1": "ftp",
    "2": "tcp",
    "3": "udp",
    "4": "ssl bridge",
    "5": "monitor",
    "6": "monitor udp",
    "7": "nntp",
    "8": "http server",
    "9": "http client",
    "10": "rpc server",
    "11": "rpc client",
    "12": "nat",
    "13": "any",
    "14": "ssl",
    "15": "dns",
    "16": "adns",
    "17": "snmp",
    "18": "ha",
    "19": "monitor ping",
    "20": "sslOther tcp",
    "21": "aaa",
    "23": "secure monitor",
    "24": "ssl vpn udp",
    "25": "rip",
    "26": "dns client",
    "27": "rpc server",
    "28": "rpc client",
    "62": "service unknown",
    "69": "tftp",
}

NETSCALER_ENTITYTYPES = {
    "0": "unknown",
    "1": "loadbalancing",
    "2": "loadbalancing group",
    "3": "ssl vpn",
    "4": "content switching",
    "5": "cache redirection",
}

NETSCALER_BASE_OID = ".1.3.6.1.4.1.5951.4.1.3.1.1"
COL_NAME = "1"
COL_IP = "2"
COL_PORT = "3"
COL_TYPE = "4"
COL_STATE = "5"
COL_HEALTH = "62"
COL_ENTITYTYPE = "64"
COL_REQUEST_RATE = "43"
COL_RX = "44"
COL_TX = "45"
COL_FULL_NAME = "59"
NETSCALER_DETECT_OID = ".1.3.6.1.2.1.1.1.0"


def _safe_int(s):
    return int(s) if s.isdigit() else 0


def _safe_float(s):
    stripped = s.strip()
    if stripped == "" or stripped == "-":
        return 0.0
    dot_seen = False
    digits_seen = False
    start = 0
    if stripped.startswith("-") or stripped.startswith("+"):
        start = 1
    for ch_idx in range(start, len(stripped)):
        ch = stripped[ch_idx]
        if ch == ".":
            if dot_seen:
                return 0.0
            dot_seen = True
        elif ch >= "0" and ch <= "9":
            digits_seen = True
        else:
            return 0.0
    return float(stripped) if digits_seen else 0.0


def _parse_walk_line(line):
    parts = line.split(" ", 1)
    if len(parts) < 2:
        return None
    return parts[0], parts[1].strip()


def _walk_table(ctx, params, column_oid):
    args = ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", params.get("host", "localhost"), column_oid]
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        parsed = _parse_walk_line(line)
        if parsed == None:
            continue
        oid, value = parsed
        idx = oid[len(column_oid):]
        if idx.startswith("."):
            idx = idx[1:]
        out.append([idx, value])
    return out


def _column_map(ctx, params, column_oid):
    rows = _walk_table(ctx, params, column_oid)
    m = {}
    for idx, value in rows:
        m[idx] = value
    return m


def _gather_vservers(ctx, params, base_oid):
    name_rows = _walk_table(ctx, params, base_oid + "." + COL_NAME)
    cols = {}
    col_oids = [COL_NAME, COL_IP, COL_PORT, COL_TYPE, COL_STATE, COL_HEALTH,
                COL_ENTITYTYPE, COL_REQUEST_RATE, COL_RX, COL_TX, COL_FULL_NAME]
    for c in col_oids:
        cols[c] = _column_map(ctx, params, base_oid + "." + c)

    indices = []
    seen = {}
    for idx, value in name_rows:
        if idx in seen:
            continue
        seen[idx] = True
        indices.append(idx)

    servers = []
    for idx in indices:
        name = cols[COL_NAME].get(idx, "")
        ip = cols[COL_IP].get(idx, "0.0.0.0")
        port = cols[COL_PORT].get(idx, "0")
        svr_type = cols[COL_TYPE].get(idx, "0")
        svr_state = cols[COL_STATE].get(idx, "0")
        svr_health = cols[COL_HEALTH].get(idx, "0")
        svr_entitytype = cols[COL_ENTITYTYPE].get(idx, "0")
        req_rate = cols[COL_REQUEST_RATE].get(idx, "0")
        rx_bytes = cols[COL_RX].get(idx, "0")
        tx_bytes = cols[COL_TX].get(idx, "0")
        full_name = cols[COL_FULL_NAME].get(idx, "")

        state_entry = NETSCALER_STATES.get(svr_state, [1, "unknown"])
        entity_type = NETSCALER_ENTITYTYPES.get(svr_entitytype, "unknown (%s)" % svr_entitytype)
        proto = NETSCALER_TYPES.get(svr_type, "service unknown (%s)" % svr_type)
        socket = ip + ":" + port

        vserver = {
            "service_state": state_entry,
            "entity_service_type": entity_type,
            "protocol": proto,
            "socket": socket,
            "request_rate": _safe_int(req_rate),
            "rx_bytes": _safe_int(rx_bytes),
            "tx_bytes": _safe_int(tx_bytes),
        }
        if svr_entitytype in ("1", "2"):
            vserver["health"] = _safe_float(svr_health)

        item_name = full_name or name
        if item_name == "":
            item_name = name
        servers.append([item_name, vserver])

    return servers


def _is_netscaler(ctx, params):
    args = ["snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"), NETSCALER_DETECT_OID]
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return False
    return "citrix" in res.stdout.lower()


def main(ctx, params):
    if not _is_netscaler(ctx, params):
        return {
            "changed": False,
            "msg": "NetScaler device not detected at " + params.get("host", "localhost"),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        servers = _gather_vservers(ctx, params, NETSCALER_BASE_OID)
        discovery = []
        for item_name, vserver in servers:
            if vserver.get("entity_service_type") == "loadbalancing group":
                continue
            entry = {
                "item": item_name,
                "params": {
                    "health_levels": params.get("health_levels", [100.0, 0.1]),
                    "cluster_status": params.get("cluster_status", "best"),
                },
                "metrics": ["health_perc", "request_rate", "if_in_octets", "if_out_octets"],
            }
            discovery.append(entry)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    servers = _gather_vservers(ctx, params, NETSCALER_BASE_OID)

    found = None
    for item_name, vserver in servers:
        if vserver.get("entity_service_type") == "loadbalancing group":
            continue
        if item_name == item:
            found = vserver
            break

    if found == None:
        return {
            "changed": False,
            "msg": "no such vserver: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_entry = found.get("service_state", [1, "unknown"])
    state_num = state_entry[0]
    state_name = state_entry[1]

    if state_num == 0:
        state = "OK"
    elif state_num == 1:
        state = "WARN"
    else:
        state = "CRIT"

    metrics = {}
    details_lines = []

    if found.get("health") != None and found.get("entity_service_type") in ("loadbalancing", "loadbalancing group"):
        health = found["health"]
        metrics["health_perc"] = health
        details_lines.append("Health: %f%%" % health)
    else:
        details_lines.append("Type: %s, Protocol: %s, Socket: %s" % (
            found.get("entity_service_type", "unknown"),
            found.get("protocol", "unknown"),
            found.get("socket", "unknown"),
        ))

    req_rate = found.get("request_rate", 0)
    metrics["request_rate"] = float(req_rate)
    details_lines.append("Request rate: %s/s" % str(req_rate))

    rx = found.get("rx_bytes", 0)
    tx = found.get("tx_bytes", 0)
    metrics["if_in_octets"] = float(rx)
    metrics["if_out_octets"] = float(tx)
    details_lines.append("In: %s Bit/s" % str(rx))
    details_lines.append("Out: %s Bit/s" % str(tx))

    msg = "Status: %s" % state_name
    if found.get("health") != None:
        msg = msg + ", Health: %f%%" % found["health"]

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "\n".join(details_lines),
        },
    }