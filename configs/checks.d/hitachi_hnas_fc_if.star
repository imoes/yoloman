def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)

_FC_IF_OID = "1.3.6.1.4.1.11096.6.1.1.1.3.6.25.1"

_FC_IF_COLS = {
    0: "cluster_node",
    1: "interface_index",
    2: "interface_status",
    3: "link_speed",
    4: "in_rate",
    5: "out_rate",
    6: "signal_loss",
    7: "bad_rx_char",
    8: "loss_sync",
    9: "link_fail",
    10: "rx_eof",
    11: "bad_crc",
    12: "protocol_err",
    13: "discarded_frame",
}


def _ok(res):
    if res.rc != 0:
        return False
    if res.stdout == "":
        return False
    return True


def _is_hitachi_hnas_with(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return False
    if "11096" not in res.stdout:
        return False
    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         "1.3.6.1.4.1.11096.6.1.1.1.3.6.25.1.1"],
        mutates=False,
    )
    return probe.rc == 0 and probe.stdout != ""


def _safe_int(value):
    if value == None or value == "":
        return 0
    return int(value) if value.lstrip("-").isdigit() else 0


def _parse_walk_table(stdout):
    rows = {}
    for line in stdout.splitlines():
        space = line.find(" ")
        if space < 0:
            continue
        oid = line[:space]
        value = line[space + 1:]
        suffix = oid[len(_FC_IF_OID) + 1:]
        if "." not in suffix:
            continue
        dot = suffix.find(".")
        col_idx_str = suffix[:dot]
        col_idx = int(col_idx_str) if col_idx_str.isdigit() else -1
        if col_idx not in _FC_IF_COLS:
            continue
        idx = suffix[dot + 1:]
        col_name = _FC_IF_COLS[col_idx]
        if idx not in rows:
            rows[idx] = {}
        rows[idx][col_name] = value
    return rows


def discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_hitachi_hnas_with(ctx, host, community):
        return {"changed": False, "msg": "no Hitachi HNAS device found",
                "data": {"discovery": []}}

    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _FC_IF_OID],
        mutates=False,
    )

    if walk.rc != 0 or walk.stdout == "":
        return {"changed": False, "msg": "failed to walk FC interface table",
                "data": {"discovery": []}}

    rows = _parse_walk_table(walk.stdout)

    services = []
    for idx in sorted(rows.keys()):
        row = rows[idx]
        node = row.get("cluster_node", "")
        ifindex = row.get("interface_index", "")
        item = node + "." + ifindex
        services.append({
            "item": item,
            "params": {"warn": None, "crit": None},
            "metrics": ["ifInOctets", "ifOutOctets", "ifInErrors", "ifOutErrors"],
        })

    return {"changed": False, "msg": "discovered %d FC interfaces" % len(services),
            "data": {"discovery": services}}


def _fetch_row(ctx, host, community, node, ifindex):
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _FC_IF_OID],
        mutates=False,
    )
    if walk.rc != 0 or walk.stdout == "":
        return None

    rows = _parse_walk_table(walk.stdout)

    target = node + "." + ifindex
    for idx in rows:
        row = rows[idx]
        if row.get("cluster_node", "") + "." + row.get("interface_index", "") == target:
            return row
    return None


def _grade_errors(warn, crit, total_errors):
    if warn == None or crit == None:
        return "OK"
    if total_errors >= crit:
        return "CRIT"
    if total_errors >= warn:
        return "WARN"
    return "OK"


def check(ctx, params):
    item = params.get("item", "")
    warn = params.get("warn")
    crit = params.get("crit")

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_hitachi_hnas_with(ctx, host, community):
        return {"changed": False,
                "msg": "no Hitachi HNAS device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    node, _, ifindex = item.partition(".")

    row = _fetch_row(ctx, host, community, node, ifindex)
    if row == None:
        return {"changed": False,
                "msg": "interface %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    in_octets = _safe_int(row.get("in_rate", "0"))
    out_octets = _safe_int(row.get("out_rate", "0"))

    err_cols = ["signal_loss", "bad_rx_char", "loss_sync", "link_fail",
                "rx_eof", "bad_crc", "protocol_err"]
    in_err = 0
    for c in err_cols:
        in_err += _safe_int(row.get(c, "0"))

    out_err = in_err

    status = row.get("interface_status", "2")
    if status == "1":
        link_state = "up"
    else:
        link_state = "down"

    speed = _safe_int(row.get("link_speed", "0")) * 1000000000

    total_errors = in_err + out_err
    details = ("Link: %s, Speed: %d Gbps, InOctets: %d, OutOctets: %d, Errors: %d" % (
        link_state, _safe_int(row.get("link_speed", "0")), in_octets, out_octets, total_errors))

    metrics = {}
    metrics["ifInOctets"] = in_octets
    metrics["ifOutOctets"] = out_octets
    metrics["ifInErrors"] = in_err
    metrics["ifOutErrors"] = out_err
    if speed > 0:
        metrics["ifSpeed"] = speed

    if link_state == "down":
        state = "CRIT"
        msg = "Interface %s is down" % item
    else:
        state = _grade_errors(warn, crit, total_errors)
        if state == "OK":
            msg = "Interface %s %s, %d errors" % (item, link_state, total_errors)
        elif state == "WARN":
            msg = "Interface %s %s, WARNING: %d errors" % (item, link_state, total_errors)
        else:
            msg = "Interface %s %s, CRITICAL: %d errors" % (item, link_state, total_errors)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}