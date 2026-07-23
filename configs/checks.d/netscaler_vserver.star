BASE_OID = ".1.3.6.1.4.1.5951.4.1.3.1.1"
BASE_OID_DOT = ".1.3.6.1.4.1.5951.4.1.3.1.1."

VSERVER_STATES = {
    "0": (1, "unknown"),
    "1": (2, "down"),
    "2": (1, "unknown"),
    "3": (1, "busy"),
    "4": (1, "out of service"),
    "5": (1, "transition to out of service"),
    "7": (0, "up"),
}

VSERVER_TYPES = {
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

ENTITY_TYPES = {
    "0": "unknown",
    "1": "loadbalancing",
    "2": "loadbalancing group",
    "3": "ssl vpn",
    "4": "content switching",
    "5": "cache redirection",
}

WANTED_COLS = {
    "1": True, "2": True, "3": True, "4": True, "5": True,
    "43": True, "44": True, "45": True, "59": True, "62": True, "64": True,
}

STATE_NAMES = ["OK", "WARN", "CRIT"]

def _to_int(s, default=0):
    s = s.strip()
    if not s:
        return default
    neg = s.startswith("-")
    digits = s[1:] if neg else s
    if not digits.isdigit():
        return default
    return int(s)

def _parse_snmp_val(val_str):
    colon = val_str.find(": ")
    if colon >= 0:
        v = val_str[colon + 2:].strip()
    else:
        v = val_str.strip()
    if v.startswith('"') and v.endswith('"'):
        v = v[1:-1]
    return v

def _walk_table(ctx, host, community):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
        mutates=False,
        ok_codes=[0, 1, 2],
    )
    rows = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line.startswith(BASE_OID_DOT):
            continue
        eq = line.find(" = ")
        if eq < 0:
            continue
        oid_part = line[:eq]
        val_str = line[eq + 3:]
        suffix = oid_part[len(BASE_OID_DOT):]
        dot = suffix.find(".")
        if dot < 0:
            continue
        col = suffix[:dot]
        instance = suffix[dot + 1:]
        if col not in WANTED_COLS:
            continue
        v = _parse_snmp_val(val_str)
        if instance not in rows:
            rows[instance] = {}
        rows[instance][col] = v
    return rows

def _build_vservers(rows):
    vservers = {}
    for instance in rows:
        cols = rows[instance]
        name = cols.get("1", "")
        full_name = cols.get("59", "")
        ip = cols.get("2", "0.0.0.0")
        port = cols.get("3", "0")
        svr_type = cols.get("4", "0")
        svr_state = cols.get("5", "0")
        svr_health_str = cols.get("62", "0")
        svr_entity = cols.get("64", "0")
        req_rate_str = cols.get("43", "0")
        rx_str = cols.get("44", "0")
        tx_str = cols.get("45", "0")

        display_name = full_name if full_name else name
        if not display_name:
            continue

        state_entry = VSERVER_STATES.get(svr_state, (1, "unknown"))
        entity_type = ENTITY_TYPES.get(svr_entity, "unknown (%s)" % svr_entity)
        protocol = VSERVER_TYPES.get(svr_type, "service unknown (%s)" % svr_type)

        vs = {
            "service_state": state_entry,
            "entity_service_type": entity_type,
            "protocol": protocol,
            "socket": "%s:%s" % (ip, port),
            "request_rate": _to_int(req_rate_str),
            "rx_bytes": _to_int(rx_str),
            "tx_bytes": _to_int(tx_str),
        }

        if svr_entity == "1" or svr_entity == "2":
            vs["health"] = float(_to_int(svr_health_str))

        vservers[display_name] = vs
    return vservers

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    rows = _walk_table(ctx, host, community)

    if params.get("_discover"):
        vservers = _build_vservers(rows)
        discovery = []
        for name in vservers:
            vs = vservers[name]
            if vs["entity_service_type"] == "loadbalancing group":
                continue
            metrics = ["request_rate", "if_in_octets", "if_out_octets"]
            if "health" in vs:
                metrics = ["health_perc"] + metrics
            discovery.append({
                "item": name,
                "params": {"health_levels": [100.0, 0.1], "cluster_status": "best"},
                "metrics": metrics,
            })
        return {
            "changed": False,
            "msg": "discovered %d vservers" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    vservers = _build_vservers(rows)

    if item not in vservers:
        return {
            "changed": False,
            "msg": "VServer not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    vs = vservers[item]
    health_levels = params.get("health_levels", [100.0, 0.1])
    health_warn = float(health_levels[0])
    health_crit = float(health_levels[1])

    svc_state = vs["service_state"]
    svc_state_num = svc_state[0]
    svc_state_txt = svc_state[1]
    overall = svc_state_num

    msg_parts = ["Status: " + svc_state_txt]

    metrics = {
        "request_rate": float(vs["request_rate"]),
        "if_in_octets": float(vs["rx_bytes"]),
        "if_out_octets": float(vs["tx_bytes"]),
    }

    if "health" in vs:
        health = vs["health"]
        if health < health_crit:
            h_state = 2
        elif health < health_warn:
            h_state = 1
        else:
            h_state = 0
        overall = h_state if h_state > overall else overall
        msg_parts.append("Health: %f%%" % health)
        metrics["health_perc"] = health

    msg_parts.append("Type: %s, Protocol: %s, Socket: %s" % (
        vs["entity_service_type"], vs["protocol"], vs["socket"],
    ))
    msg_parts.append("Request rate: %d/s" % vs["request_rate"])

    if (overall >= 0) and (overall <= 2):
        state_str = STATE_NAMES[overall]
    else:
        state_str = "UNKNOWN"

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": "",
        },
    }