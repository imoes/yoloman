def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    sys_descr = _snmp_scalar(ctx, params, "1.3.6.1.2.1.1.1.0")
    tree_exists = _snmp_exists(ctx, params, "1.3.6.1.4.1.9.9.176.1.1")
    if not _product_present(sys_descr, tree_exists):
        return {"changed": False, "msg": "no cisco redundancy on this host",
                "data": {"discovery": []}}

    row = _snmp_row(ctx, params, "1.3.6.1.4.1.9.9.176.1.1",
                    ["1", "2", "3", "4", "6", "8"])
    if not row or len(row) < 6:
        return {"changed": False, "msg": "no cisco redundancy on this host",
                "data": {"discovery": []}}

    swact_reason = row[5]
    if swact_reason == "1":
        return {"changed": False, "msg": "supported mode - no service",
                "data": {"discovery": []}}

    init_states = row[:5]
    return {"changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "",
                 "params": {"init_states": init_states},
                 "metrics": []}
            ]}}


def _check(ctx, params):
    sys_descr = _snmp_scalar(ctx, params, "1.3.6.1.2.1.1.1.0")
    tree_exists = _snmp_exists(ctx, params, "1.3.6.1.4.1.9.9.176.1.1")
    if not _product_present(sys_descr, tree_exists):
        return {"changed": False, "msg": "no cisco redundancy on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    row = _snmp_row(ctx, params, "1.3.6.1.4.1.9.9.176.1.1",
                    ["1", "2", "3", "4", "6", "8"])
    if not row or len(row) < 6:
        return {"changed": False, "msg": "no cisco redundancy data on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    init_states = params.get("init_states", row[:5])
    return _evaluate(row, init_states)


# ---- SNMP helpers -----------------------------------------------------------

def _community(params):
    return params.get("community", "public")

def _host(params):
    return params.get("host", "localhost")

def _ver(params):
    return params.get("snmp_version", "2c")

def _snmp_base_args(params):
    ver = _ver(params)
    comm = _community(params)
    host = _host(params)
    if ver == "2c":
        return ["-v2c", "-c", comm, host]
    elif ver == "1":
        return ["-v1", "-c", comm, host]
    else:
        return ["-v3", "-u", comm, host]

def _snmp_get(ctx, params, oid):
    args = ["snmpget"] + _snmp_base_args(params) + ["-Oqv", oid]
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _snmp_scalar(ctx, params, oid):
    return _snmp_get(ctx, params, oid)

def _snmp_exists(ctx, params, base):
    args = ["snmpwalk"] + _snmp_base_args(params) + ["-Oqn", "-Cr1", base]
    res = ctx.run(args, mutates=False)
    return res.rc == 0 and len(res.stdout.strip()) > 0

def _snmp_walk(ctx, params, base):
    args = ["snmpwalk"] + _snmp_base_args(params) + ["-Oqn", base]
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) == 2:
            out.append((sp[0], sp[1]))
    return out

def _snmp_row(ctx, params, base, oids):
    row = []
    for suffix in oids:
        oid = base + "." + suffix + ".0"
        val = _snmp_get(ctx, params, oid)
        if val == "":
            walked = _snmp_walk(ctx, params, base + "." + suffix)
            if len(walked) > 0:
                val = walked[0][1]
            else:
                val = ""
        row.append(val)
    return row


# ---- product detection ------------------------------------------------------

def _product_present(sys_descr, tree_exists):
    if tree_exists:
        return True
    if sys_descr == "":
        return False
    low = sys_descr.lower()
    return low.find("cisco") >= 0


def _evaluate(row, init_states):
    unit_id, unit_state, peer_id, peer_state, duplex_mode, swact_reason = row[:6]

    infotexts = {}
    for what, states in [("now", row[:5]), ("init", init_states)]:
        uid, ustate, pid, pstate, dmode = states
        infotexts[what] = "Unit ID: %s (%s), Peer ID: %s (%s), Duplex mode: %s" % (
            uid,
            _state_name("unit_state", ustate),
            pid,
            _state_name("unit_state", pstate),
            _state_name("duplex_mode", dmode),
        )

    if init_states == row[:5]:
        state = "OK"
        infotext = "%s, Last swact reason code: %s" % (
            infotexts["now"],
            _state_name("swact_reason", swact_reason),
        )
    else:
        if unit_state in ["2", "9", "14"] or peer_state in ["2", "9", "14"]:
            state = "WARN"
        else:
            state = "CRIT"
        infotext = "Switchover - Old status: %s, New status: %s" % (
            infotexts["init"],
            infotexts["now"],
        )

    if peer_state == "1":
        state = "CRIT"

    return {"changed": False,
            "msg": infotext,
            "data": {"state": state, "metrics": {}, "details": ""}}


# ---- state maps -------------------------------------------------------------

_STATE_MAPS = {
    "unit_state": {
        "0": "not found",
        "1": "not known",
        "2": "disabled",
        "3": "initialization",
        "4": "negotiation",
        "5": "standby cold",
        "6": "standby cold config",
        "7": "standby cold file sys",
        "8": "standby cold bulk",
        "9": "standby hot",
        "10": "active fast",
        "11": "active drain",
        "12": "active pre-config",
        "13": "active post-config",
        "14": "active",
        "15": "active extra load",
        "16": "active handback",
    },
    "duplex_mode": {
        "2": "False (SUB-Peer not detected)",
        "1": "True (SUB-Peer detected)",
    },
    "swact_reason": {
        "1": "unsupported",
        "2": "none",
        "3": "not known",
        "4": "user initiated",
        "5": "user forced",
        "6": "active unit failed",
        "7": "active unit removed",
        "8": "active lost gateway connectivity",
        "9": "RMI port went down on active",
    },
}

def _state_name(what, key):
    m = _STATE_MAPS.get(what, {})
    if key in m:
        return m[key]
    return key