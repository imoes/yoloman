# ===== check plugin: checkmk.openbsd_sensors_powersupply (Starlark translation) =====
#
# Read-only Starlark check module (v1 contract).
#
# This check is an SNMP check. It monitors OpenBSD sensor power-supply status
# via the enterprise MIB 1.3.6.1.4.1.30155 (OpenBSD).
#
# Source Checkmk plugin:
#   - SNMP section "openbsd_sensors" fetched from base .1.3.6.1.4.1.30155.2.1.2.1
#     columns: 2=descr, 3=sensortype, 5=value, 6=unit, 7=state
#   - "powersupply" sensortype == "21"
#   - check function: emits Result(state=data["state"], summary="Status: <value>")
#     where state is one of 0=UNKNOWN,1=OK,2=WARN,3=CRIT.
#
# This translation reproduces ONLY the powersupply sub-check (the requested one).
# Discovery requires the detect OID (.1.3.6.1.4.1.30155.2.1.1.0) to exist on the host.

_OPENBSD_SENSORS_BASE = ".1.3.6.1.4.1.30155.2.1.2.1"
_OPENBSD_DETECT_OID = ".1.3.6.1.4.1.30155.2.1.1.0"

# sensortype -> type name
_OPENBSD_MAP_TYPE = {
    "0": "temp",
    "1": "fan",
    "2": "voltage",
    "9": "indicator",
    "13": "drive",
    "21": "powersupply",
}

# state number -> Checkmk state name
_OPENBSD_MAP_STATE = {
    "0": "UNKNOWN",
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
}

_STATE_TO_CODE = {
    "UNKNOWN": 3,
    "OK": 0,
    "WARN": 1,
    "CRIT": 2,
}


def _strip_type_prefix(value):
    # SNMP output via -Oqv is the bare value; if any type prefix leaked in
    # (e.g. "STRING: foo"), strip everything up to and including the first ": ".
    p = value.find(": ")
    if p != -1:
        return value[p + 2:]
    return value


def _snmp_get_scalar(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _fetch_powersupplies(ctx, host, community):
    # Walk the whole sensor table column-wise. Base columns:
    # 2=descr, 3=sensortype, 5=value, 6=unit, 7=state
    cols = {
        "2": "descr",
        "3": "sensortype",
        "5": "value",
        "6": "unit",
        "7": "state",
    }
    rows = {}
    for suffix, name in cols.items():
        oid = _OPENBSD_SENSORS_BASE + "." + suffix
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            line_oid = line[:sp]
            line_val = _strip_type_prefix(line[sp + 1:])
            # index is the oid suffix after the column base
            idx = line_oid[len(oid) + 1:]
            if not idx:
                continue
            e = rows.setdefault(idx, {"index": idx})
            e[name] = line_val
    # Keep only powersupply entries
    out = {}
    used = {}
    for idx, e in rows.items():
        st = e.get("sensortype")
        if st not in _OPENBSD_MAP_TYPE:
            continue
        if _OPENBSD_MAP_TYPE[st] != "powersupply":
            continue
        descr = e.get("descr", "")
        # dedup item names like get_item_name
        nm = descr
        i = 0
        while nm in used:
            nm = "%s/%d" % (descr, i)
            i = i + 1
        used[nm] = True
        out[nm] = {
            "state": _OPENBSD_MAP_STATE.get(e.get("state", "0"), "UNKNOWN"),
            "value": e.get("value", ""),
            "unit": e.get("unit", ""),
            "type": "powersupply",
        }
    return out


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe detect OID first.
        det = _snmp_get_scalar(ctx, host, community, _OPENBSD_DETECT_OID)
        if det == None:
            return {
                "changed": False,
                "msg": "no OpenBSD sensors detected (detect OID missing)",
                "data": {"discovery": [], "host_labels": {}},
            }
        section = _fetch_powersupplies(ctx, host, community)
        discovery = []
        for name in section:
            discovery.append({
                "item": name,
                "params": {},
                "metrics": ["status"],
            })
        return {
            "changed": False,
            "msg": "discovered %d powersupplies" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {"cmk/os_family": "openbsd"},
            },
        }

    item = params.get("item", "")
    # Probe detect OID first.
    det = _snmp_get_scalar(ctx, host, community, _OPENBSD_DETECT_OID)
    if det == None:
        return {
            "changed": False,
            "msg": "no OpenBSD sensors detected (detect OID missing)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _fetch_powersupplies(ctx, host, community)
    data = section.get(item) if item else None
    if not data:
        return {
            "changed": False,
            "msg": "no such powersupply: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    # State value: numeric code from data["state"] name
    state_name = data["state"]
    code = _STATE_TO_CODE.get(state_name, 3)
    value = data["value"]
    state = state_name
    if state_name == "OK":
        state = "OK"
    elif state_name == "WARN":
        state = "WARN"
    elif state_name == "CRIT":
        state = "CRIT"
    else:
        state = "UNKNOWN"
    # Map state name to a numeric metric for perfdata
    state_metric = 0
    if state_name == "OK":
        state_metric = 0
    elif state_name == "WARN":
        state_metric = 1
    elif state_name == "CRIT":
        state_metric = 2
    else:
        state_metric = 3
    summary = "Status: %s" % value
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"status": state_metric},
            "details": summary,
        },
    }