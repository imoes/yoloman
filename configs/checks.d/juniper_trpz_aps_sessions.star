AP_STATES = {
    "1": ("CRIT", "cleared"),
    "2": ("WARN", "init"),
    "3": ("CRIT", "boot started"),
    "4": ("CRIT", "image downloaded"),
    "5": ("CRIT", "connect failed"),
    "6": ("WARN", "configuring"),
    "7": ("OK", "operational"),
    "10": ("OK", "redundant"),
    "20": ("CRIT", "conn outage"),
}

AP_OID_BASE = ".1.3.6.1.4.1.14525.4.5.1.1"
AP_TREE = ".1"
RADIO_TREE = ".1"
SYS_OID = ".1.3.6.1.2.1.1.2.0"
TRPZ_AP_ROOTS = [".1.3.6.1.4.1.14525.3.1", ".1.3.6.1.4.1.14525.3.3"]


def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return []
    out = []
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        out.append((sp[0], sp[1]))
    return out


def _get_system_oid(ctx, community, host):
    return _snmp_get(ctx, community, host, SYS_OID)


def _is_trpz(host_oid):
    for root in TRPZ_AP_ROOTS:
        if host_oid.startswith(root):
            return True
    return False


def _fetch_aps(ctx, community, host):
    base = AP_OID_BASE + AP_TREE + ".1.2.1"
    rows = _snmp_walk(ctx, community, host, base)
    aps = {}
    for oid, val in rows:
        parts = oid.split(".")
        if len(parts) < 2:
            continue
        idx = parts[-1]
        name_oid = base + "." + idx + ".8"
        status_oid = base + "." + idx + ".5"
        ap_name = _snmp_get(ctx, community, host, name_oid)
        status = _snmp_get(ctx, community, host, status_oid)
        if ap_name == "" or status == "":
            continue
        clean_name = ap_name.replace("AP-", "")
        aps[clean_name] = {"oid": oid, "status": status}
    return aps


def _fetch_radios(ctx, community, host):
    base = AP_OID_BASE + RADIO_TREE + ".10.1"
    rows = _snmp_walk(ctx, community, host, base)
    radios = {}
    for oid, _val in rows:
        suffix = oid[len(base) + 1:]
        idx_parts = suffix.split(".")
        if len(idx_parts) != 2:
            continue
        ap_oid_suffix = idx_parts[0]
        radio_num = idx_parts[1]
        full_oid = oid
        cols = {}
        col_oids = {
            "counters": [3, 4, 5, 6, 7, 8],
            "sessions": 15,
            "noise_floor": 16,
        }
        counter_vals = []
        ok = True
        for col_idx in [3, 4, 5, 6, 7, 8]:
            v = _snmp_get(ctx, community, host, full_oid[:-len(idx_parts[1]) - 1] + "." + str(col_idx))
            if v == "":
                ok = False
                break
            counter_vals.append(int(v) if v.isdigit() else 0)
        if not ok:
            continue
        sessions_v = _snmp_get(ctx, community, host, full_oid[:-len(idx_parts[1]) - 1] + ".15")
        noise_v = _snmp_get(ctx, community, host, full_oid[:-len(idx_parts[1]) - 1] + ".16")
        sessions = int(sessions_v) if sessions_v.isdigit() else 0
        noise_floor = int(noise_v) if noise_v.lstrip("-").isdigit() else 0
        radios.setdefault(ap_oid_suffix, {})[radio_num] = (
            counter_vals, sessions, noise_floor
        )
    return radios


def _gather(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sys_oid = _get_system_oid(ctx, community, host)
    if sys_oid == "":
        return None, None
    if not _is_trpz(sys_oid):
        return None, None
    aps = _fetch_aps(ctx, community, host)
    if not aps:
        return aps, {}
    radios = _fetch_radios(ctx, community, host)
    return aps, radios


def main(ctx, params):
    if params.get("_discover"):
        aps, _radios = _gather(ctx, params)
        if aps == None:
            return {"changed": False, "msg": "not a juniper trpz device", "data": {"discovery": [], "host_labels": {}}}
        discovery = []
        for name in sorted(aps.keys()):
            discovery.append({
                "item": name,
                "params": {},
                "metrics": [
                    "if_out_unicast", "if_out_unicast_octets",
                    "if_out_non_unicast", "if_out_non_unicast_octets",
                    "if_in_pkts", "if_in_octets",
                    "wlan_physical_errors", "wlan_resets", "wlan_retries",
                    "total_sessions", "noise_floor",
                ],
            })
        return {
            "changed": False,
            "msg": "discovered %d access points" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    aps, radios = _gather(ctx, params)
    if aps == None:
        return {"changed": False, "msg": "not a juniper trpz device", "data": {"state": "UNKNOWN", "metrics": {}, "details": "device is not a juniper trpz"}}
    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item not in aps:
        return {"changed": False, "msg": "access point not found: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ap = aps[item]
    status = ap["status"]
    state_code, state_string = AP_STATES.get(status, ("UNKNOWN", "unknown"))
    summary = "Status: %s" % state_string

    m = {}
    if state_code == "OK":
        m["if_out_unicast"] = 0.0
        m["if_out_unicast_octets"] = 0.0
        m["if_out_non_unicast"] = 0.0
        m["if_out_non_unicast_octets"] = 0.0
        m["if_in_pkts"] = 0.0
        m["if_in_octets"] = 0.0
        m["wlan_physical_errors"] = 0.0
        m["wlan_resets"] = 0.0
        m["wlan_retries"] = 0.0
        m["total_sessions"] = 0.0
        m["noise_floor"] = 0.0
    else:
        for name in ["if_out_unicast", "if_out_unicast_octets", "if_out_non_unicast", "if_out_non_unicast_octets", "if_in_pkts", "if_in_octets", "wlan_physical_errors", "wlan_resets", "wlan_retries", "total_sessions", "noise_floor"]:
            m[name] = 0.0

    return {"changed": False, "msg": summary, "data": {"state": state_code, "metrics": m, "details": ""}}