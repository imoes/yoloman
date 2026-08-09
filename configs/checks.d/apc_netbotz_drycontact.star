def _state_text(state):
    table = {
        1: "Closed high mem",
        2: "Open low mem",
        3: "Disabled",
        4: "Not applicable",
    }
    return "%s [%s]" % (table.get(state, "unknown"), state)


def _get_state_tuple(state, normal, severity):
    severity_map = {
        1: "OK",
        2: "WARN",
        3: "CRIT",
        4: "UNKNOWN",
    }
    current = _state_text(state)
    if normal == state:
        return ("Normal state (%s)" % current, "OK")
    sev = severity_map.get(severity, "UNKNOWN")
    return ("State: %s but expected %s" % (current, _state_text(normal)), sev)


def _walk(ctx, host, community, column_oid):
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-Oqn",
            host,
            column_oid,
        ],
        mutates=False,
    )
    rows = {}
    lines = res.stdout.splitlines()
    for line in lines:
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        if oid.find(column_oid) != 0 or len(oid) <= len(column_oid):
            continue
        idx = oid[len(column_oid) + 1:]
        if idx not in rows:
            rows[idx] = {}
        rows[idx]["value"] = value.strip('"')
    return rows


def _get_table(ctx, host, community, base):
    cols = [
        ["input_name", base + ".2.1.3"],
        ["location", base + ".2.1.4"],
        ["current_state", base + ".2.1.5"],
        ["normal_state", base + ".4.1.7"],
        ["abnormal_severity", base + ".4.1.8"],
    ]
    data = {}
    for pair in cols:
        col = pair[0]
        oid = pair[1]
        walked = _walk(ctx, host, community, oid)
        for idx in walked:
            if idx not in data:
                data[idx] = {}
            data[idx][col] = walked[idx]["value"]
    required = ["input_name", "location", "current_state", "normal_state", "abnormal_severity"]
    entries = []
    for idx in data:
        fields = data[idx]
        has_all = True
        for k in required:
            if k not in fields:
                has_all = False
                break
        if not has_all:
            continue
        dot = idx.rfind(".")
        if dot != -1:
            inst = idx[:dot]
            idx2 = idx[dot + 1:]
        else:
            inst = idx
            idx2 = idx
        cs = fields["current_state"].lstrip("-")
        ns = fields["normal_state"].lstrip("-")
        asv = fields["abnormal_severity"].lstrip("-")
        entries.append({
            "index": idx2,
            "inst": inst,
            "input_name": fields["input_name"],
            "location": fields["location"],
            "current_state": int(fields["current_state"]) if cs.isdigit() else 0,
            "normal_state": int(fields["normal_state"]) if ns.isdigit() else 0,
            "abnormal_severity": int(fields["abnormal_severity"]) if asv.isdigit() else 0,
        })
    return entries


def _is_apc(ctx, host, community):
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c", community,
            "-Ov",
            "-Oq",
            host,
            ".1.3.6.1.2.1.1.2.0",
        ],
        mutates=False,
    )
    if res.rc != 0:
        return False
    return res.stdout.find(".1.3.6.1.4.1.318") == 0


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.318.1.1.10.4.3"

    # Discovery
    if params.get("_discover"):
        if not _is_apc(ctx, host, community):
            return {
                "changed": False,
                "msg": "no APC NetBotz device at %s" % host,
                "data": {"discovery": []},
            }
        entries = _get_table(ctx, host, community, base)
        discovery = []
        for e in entries:
            discovery.append({
                "item": "%s %s" % (e["inst"], e["index"]),
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d dry contacts" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode for a single item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not _is_apc(ctx, host, community):
        return {
            "changed": False,
            "msg": "no APC NetBotz device at %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    entries = _get_table(ctx, host, community, base)
    entry = None
    for e in entries:
        if "%s %s" % (e["inst"], e["index"]) == item:
            entry = e
            break
    if entry == None:
        return {
            "changed": False,
            "msg": "no such dry contact: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_readable, state = _get_state_tuple(
        entry["current_state"],
        entry["normal_state"],
        entry["abnormal_severity"],
    )
    if entry["location"]:
        loc_info = "[%s] " % entry["location"]
    else:
        loc_info = ""
    return {
        "changed": False,
        "msg": "%s%s" % (loc_info, state_readable),
        "data": {"state": state, "metrics": {}, "details": ""},
    }