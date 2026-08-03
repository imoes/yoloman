# Translated from Checkmk check: apc_mod_pdu_modules
# Monitors APC Modular PDU modules via SNMP.

APC_STATES = {
    1: "normal",
    2: "warning",
    3: "notPresent",
    6: "unknown",
}

OID_BASE = ".1.3.6.1.4.1.318.1.1.22.2.6.1"
NAME_OID = "4"
STATUS_OID = "6"
POWER_OID = "20"
DETECT_OID = ".1.3.6.1.2.1.1.2.0"

def _is_int_str(s):
    if s == None or s == "":
        return False
    v = s
    neg = False
    if v.startswith("-"):
        neg = True
        v = v[1:]
    if v.startswith("+"):
        v = v[1:]
    return v.isdigit()

def _saveint(s):
    if s == None:
        return 0
    s = str(s).strip()
    if not _is_int_str(s):
        return 0
    neg = False
    v = s
    if v.startswith("-"):
        neg = True
        v = v[1:]
    if v.startswith("+"):
        v = v[1:]
    val = int(v)
    return (-1 if neg else 1) * val

def _is_float_str(s):
    if s == None or s == "":
        return False
    v = str(s).strip()
    neg = False
    if v.startswith("-"):
        neg = True
        v = v[1:]
    elif v.startswith("+"):
        v = v[1:]
    if v.count(".") > 1:
        return False
    int_part = v
    has_dot = False
    frac_part = ""
    if "." in v:
        idx = v.find(".")
        int_part = v[:idx]
        frac_part = v[idx + 1:]
        has_dot = True
    if int_part == "" and frac_part == "":
        return False
    if int_part != "" and not int_part.isdigit():
        return False
    if frac_part != "" and not frac_part.isdigit():
        return False
    return True

def _savefloat(s):
    if s == None:
        return 0.0
    if not _is_float_str(s):
        return 0.0
    return float(str(s).strip())

def _strip_type(s):
    out = str(s).strip()
    idx = out.find(": ")
    if idx >= 0:
        out = out[idx + 2:]
    if len(out) >= 2 and out[0] == '"' and out[-1] == '"':
        out = out[1:-1]
    return out

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        det = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", host, DETECT_OID], mutates=False)
        if det.rc != 0:
            return {"changed": False, "msg": "no APC modular PDU found", "data": {"discovery": [], "host_labels": {}}}

        walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, OID_BASE + "." + NAME_OID], mutates=False)
        if walk_res.rc != 0:
            return {"changed": False, "msg": "failed to walk APC PDU modules", "data": {"discovery": []}}

        discovery = []
        seen_indexes = []
        for line in walk_res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            name_val = " ".join(parts[1:])
            prefix = OID_BASE + "." + NAME_OID + "."
            if not oid_full.startswith(prefix):
                continue
            index = oid_full[len(prefix):]
            if not index:
                continue
            if index in seen_indexes:
                continue
            seen_indexes.append(index)
            discovery.append({
                "item": name_val,
                "params": {},
                "metrics": ["power"],
            })

        return {
            "changed": False,
            "msg": "discovered %d modules" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    det = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", host, DETECT_OID], mutates=False)
    if det.rc != 0:
        return {
            "changed": False,
            "msg": "no APC Modular PDU found (snmp unreachable)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    name_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, OID_BASE + "." + NAME_OID], mutates=False)
    if name_walk.rc != 0:
        return {
            "changed": False,
            "msg": "failed to walk APC PDU module names",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    target_index = None
    for line in name_walk.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        name_val = " ".join(parts[1:])
        prefix = OID_BASE + "." + NAME_OID + "."
        if not oid_full.startswith(prefix):
            continue
        index = oid_full[len(prefix):]
        if name_val == item:
            target_index = index
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "module not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_BASE + "." + STATUS_OID + "." + target_index], mutates=False)
    power_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_BASE + "." + POWER_OID + "." + target_index], mutates=False)

    if status_res.rc != 0 and power_res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query APC module " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_str = status_res.stdout.strip()
    if status_res.stdout == "":
        status_str = str(_strip_type(status_res.stdout))
    power_str = power_res.stdout.strip()

    status = _saveint(status_str)
    current_power = _savefloat(power_str) / 10.0

    state_name = APC_STATES.get(status, "unknown")
    message = "Status %s, current: %f kW" % (state_name, current_power)

    result_state = "OK"
    if status == 2:
        result_state = "WARN"
    elif status == 3 or status == 6:
        result_state = "CRIT"
    elif status == 1:
        result_state = "OK"
    else:
        result_state = "UNKNOWN"

    return {
        "changed": False,
        "msg": message,
        "data": {
            "state": result_state,
            "metrics": {"power": current_power * 1000},
            "details": "",
        },
    }