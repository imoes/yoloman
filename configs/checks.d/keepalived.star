STATE_CODE_MAP = {
    "0": "init",
    "1": "backup",
    "2": "master",
    "3": "fault",
    "4": "unknown",
}

DEFAULT_PARAMS = {
    "master": 0,
    "unknown": 3,
    "init": 0,
    "backup": 0,
    "fault": 2,
}

OID_NAMES  = ".1.3.6.1.4.1.9586.100.5.2.3.1.2"
OID_STATES = ".1.3.6.1.4.1.9586.100.5.2.3.1.4"
OID_IPS    = ".1.3.6.1.4.1.9586.100.5.2.6.1.3"

def _last_oid(oid_str):
    parts = oid_str.strip().split(".")
    return parts[-1]

def _snmp_val(raw):
    idx = raw.find(": ")
    if idx < 0:
        return raw.strip()
    v = raw[idx + 2:].strip()
    if len(v) > 1 and v.startswith('"') and v.endswith('"'):
        v = v[1:-1]
    return v

def _walk_to_dict(stdout):
    result = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        eq = line.find(" = ")
        if eq < 0:
            continue
        idx = _last_oid(line[:eq])
        result[idx] = _snmp_val(line[eq + 3:])
    return result

def _hex_to_ip(s):
    clean = s.strip().replace(" ", "").lower()
    if len(clean) == 8:
        parts = []
        for i in range(0, 8, 2):
            parts.append(str(int(clean[i:i+2], 16)))
        return ".".join(parts)
    if len(clean) == 32:
        groups = []
        for i in range(0, 32, 4):
            groups.append(clean[i:i+4])
        return ":".join(groups)
    return s

def _parse_ip(val):
    if val.count(".") == 3:
        parts = val.split(".")
        valid = True
        for p in parts:
            if not p.isdigit():
                valid = False
                break
        if valid:
            return val
    return _hex_to_ip(val)

def _int_key(x):
    return int(x) if x.isdigit() else 0

def _check_state(numeric):
    if numeric == 0:
        return "OK"
    if numeric == 1:
        return "WARN"
    if numeric == 2:
        return "CRIT"
    return "UNKNOWN"

def main(ctx, params):
    host      = params.get("host", "localhost")
    community = params.get("community", "public")
    ver       = params.get("snmp_version", "2c")
    snmp_base = ["-v" + ver, "-c", community, "-On", host]

    res_names  = ctx.run(["snmpwalk"] + snmp_base + [OID_NAMES],  mutates=False, ok_codes=[0, 1, 2])
    res_states = ctx.run(["snmpwalk"] + snmp_base + [OID_STATES], mutates=False, ok_codes=[0, 1, 2])
    res_ips    = ctx.run(["snmpwalk"] + snmp_base + [OID_IPS],    mutates=False, ok_codes=[0, 1, 2])

    names  = _walk_to_dict(res_names.stdout)
    states = _walk_to_dict(res_states.stdout)
    ips    = _walk_to_dict(res_ips.stdout)

    if params.get("_discover"):
        items = []
        for idx in sorted(names.keys(), key=_int_key):
            vrrp_id = names[idx]
            items.append({
                "item": vrrp_id,
                "params": {
                    "master": 0,
                    "unknown": 3,
                    "init": 0,
                    "backup": 0,
                    "fault": 2,
                },
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d VRRP instances" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    found_idx = None
    for idx in names:
        if names[idx] == item:
            found_idx = idx
            break

    if found_idx == None:
        return {
            "changed": False,
            "msg": "VRRP instance not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_raw  = states.get(found_idx, "4")
    state_name = STATE_CODE_MAP.get(state_raw, "unknown")

    ip_raw = ips.get(found_idx, "")
    ip_str = _parse_ip(ip_raw) if ip_raw != "" else "unknown"

    param_val   = params.get(state_name, DEFAULT_PARAMS.get(state_name, 3))
    check_state = _check_state(param_val)

    summary = "This node is %s. IP Address: %s" % (state_name, ip_str)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": check_state,
            "metrics": {},
            "details": "",
        },
    }