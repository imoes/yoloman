# Translated Checkmk check: checkmk.adva_fsp_if
# Interface %s — SNMP-based optical interface monitor for ADVA FSP platforms.
# Read-only Starlark check module for the yolo-man agent.

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no SNMP response / device not present",
                "data": {"discovery": []}}

    sys_descr = res.stdout.strip()
    if "Fiber Service Platform F7" not in sys_descr:
        return {"changed": False, "msg": "not an ADVA FSP F7 device",
                "data": {"discovery": []}}

    indices = _fetch_all(ctx, host, community)
    if len(indices) == 0:
        return {"changed": False, "msg": "no interface table data",
                "data": {"discovery": []}}

    discovery = []
    for idx, entry in indices.items():
        itype = entry.get("type", "")
        admin = entry.get("admin_status", "")
        if itype not in _MONITORED_TYPES:
            continue
        if admin not in _MONITORED_ADMIN_STATES:
            continue
        descr = entry.get("ifdescr", "")
        item_name = descr if descr != "" else entry.get("ifindex", idx)
        if item_name == "":
            item_name = idx
        discovery.append({
            "item": item_name,
            "params": {},
            "metrics": ["output_power", "input_power"],
        })

    return {"changed": False,
            "msg": "discovered %d interfaces" % len(discovery),
            "data": {"discovery": discovery}}


def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no SNMP response / device not present",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_descr = res.stdout.strip()
    if "Fiber Service Platform F7" not in sys_descr:
        return {"changed": False, "msg": "not an ADVA FSP F7 device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    indices = _fetch_all(ctx, host, community)
    if len(indices) == 0:
        return {"changed": False, "msg": "no interface table data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = None
    for idx, entry in indices.items():
        descr = entry.get("ifdescr", "")
        candidate = descr if descr != "" else entry.get("ifindex", idx)
        if candidate == "":
            candidate = idx
        if candidate == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "interface not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    interface = indices[target_idx]
    itype = interface.get("type", "")
    admin = interface.get("admin_status", "")
    if itype not in _MONITORED_TYPES or admin not in _MONITORED_ADMIN_STATES:
        return {"changed": False, "msg": "interface not monitored: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    admin_txt, admin_state = _MAP_OPER_STATUS.get(
        interface.get("admin_status", ""), ("unknown", "UNKNOWN"))
    oper_txt, oper_state = _MAP_OPER_STATUS.get(
        interface.get("oper_status", ""), ("unknown", "UNKNOWN"))

    state = _worst_state(admin_state, oper_state)

    metrics = {}
    results = []
    for power_type in ["output", "input"]:
        raw = interface.get(power_type, "")
        power = _to_float(raw)
        ptxt = power_type.title()
        if power == None:
            if not item.startswith("S"):
                results.append({"state": "WARN",
                                "summary": "%s power: n.a." % ptxt})
            continue
        power = power / 10.0
        params_key = "limits_%s_power" % power_type
        mon_state = "OK"
        upper = None
        if params_key in params:
            limits = params[params_key]
            if type(limits) == "list" and len(limits) == 2:
                lower = limits[0]
                upper = limits[1]
                if lower != None and upper != None:
                    mon_state = "OK" if (power >= lower and power <= upper) else "CRIT"
                elif upper != None and power > upper:
                    mon_state = "CRIT"
                elif lower != None and power < lower:
                    mon_state = "CRIT"
        metric_name = "%s_power" % power_type
        metrics[metric_name] = power
        results.append({
            "state": mon_state,
            "summary": "%s power: %f dBm" % (ptxt, power),
            "metric": metric_name,
        })

    if len(results) > 0:
        worst_state = state
        for r in results:
            worst_state = _worst_state(worst_state, r["state"])
        state = worst_state

    summary_parts = ["Admin/Operational State: %s/%s" % (admin_txt, oper_txt)]
    for r in results:
        if "summary" in r:
            summary_parts.append(r["summary"])

    return {"changed": False,
            "msg": ", ".join(summary_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _fetch_all(ctx, host, community):
    indices = {}

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Ovqn", host,
         ".1.3.6.1.2.1.2.2.1.1"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return indices
    for line in res.stdout.splitlines():
        oid, val = _split_oid_val(line)
        if oid == "" or val == "":
            continue
        base_len = len(".1.3.6.1.2.1.2.2.1.1") + 1
        idx = oid[base_len:]
        if idx != "":
            indices[idx] = {"ifindex": val}

    _consume(_walk(ctx, host, community, ".1.3.6.1.2.1.2.2.1.2"),
             indices, "ifdescr", ".1.3.6.1.2.1.2.2.1.2")
    _consume(_walk(ctx, host, community, ".1.3.6.1.2.1.2.2.1.3"),
             indices, "type", ".1.3.6.1.2.1.2.2.1.3")
    _consume(_walk(ctx, host, community, ".1.3.6.1.2.1.2.2.1.7"),
             indices, "admin_status", ".1.3.6.1.2.1.2.2.1.7")
    _consume(_walk(ctx, host, community, ".1.3.6.1.2.1.2.2.1.8"),
             indices, "oper_status", ".1.3.6.1.2.1.2.2.1.8")
    _consume(_walk(ctx, host, community, ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.4"),
             indices, "output", ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.4")
    _consume(_walk(ctx, host, community, ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.3"),
             indices, "input", ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.3")

    return indices


def _walk(ctx, host, community, oid_base):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Ovqn", host, oid_base],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout


def _consume(output, indices, key, oid_base):
    if not output or len(output.strip()) == 0:
        return
    for line in output.splitlines():
        oid, val = _split_oid_val(line)
        if oid == "" or val == "":
            continue
        base_len = len(oid_base) + 1
        if len(oid) <= base_len:
            continue
        idx = oid[base_len:]
        if idx in indices:
            indices[idx][key] = val


def _split_oid_val(line):
    parts = line.split(" ", 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return "", ""


def _to_float(s):
    s2 = str(s).strip()
    if len(s2) == 0:
        return None
    neg = False
    body = s2
    if body.startswith("-"):
        neg = True
        body = body[1:]
    if not body.isdigit():
        return None
    v = int(body)
    if neg:
        v = 0 - v
    return float(v)


def _worst_state(a, b):
    rank = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}
    if a not in rank:
        a = "UNKNOWN"
    if b not in rank:
        b = "UNKNOWN"
    ra = rank[a]
    rb = rank[b]
    if ra < rb:
        return b
    return a


_MONITORED_TYPES = ["1", "6", "56"]
_MONITORED_ADMIN_STATES = ["1"]

_MAP_OPER_STATUS = {
    "1": ("up", "OK"),
    "2": ("down", "CRIT"),
    "3": ("testing", "WARN"),
    "4": ("unknown", "UNKNOWN"),
    "5": ("dormant", "WARN"),
    "6": ("notPresent", "CRIT"),
    "7": ("lowerLayerDown", "CRIT"),
}