# ===== translated Checkmk check: fc_port (Brocade QLogic FC Interface) =====
# READ-ONLY Starlark module for the yolo-man agent.
# SNMP check: connUnitPortTable (.1.3.6.1.3.94)

fc_port_admstates = {
    1: "unknown", 2: "online", 3: "offline", 4: "bypassed", 5: "diagnostics",
}
fc_port_opstates = {
    1: "unknown", 2: "unused", 3: "ready", 4: "warning", 5: "failure",
    6: "not participating", 7: "initializing", 8: "bypass", 9: "ols",
}
fc_port_phystates = {
    1: "unknown", 2: "failed", 3: "bypassed", 4: "active", 5: "loopback",
    6: "txfault", 7: "no media", 8: "link down",
}
porttype_list = (
    "unknown", "unknown", "other", "not-present", "hub-port", "n-port",
    "l-port", "fl-port", "f-port", "e-port", "g-port", "domain-ctl",
    "hub-controller", "scsi", "escon", "lan", "wan", "ac", "dc", "ssa",
)

fc_port_no_inventory_types = [3]
fc_port_no_inventory_admstates = [1, 3]
fc_port_no_inventory_opstates = []
fc_port_no_inventory_phystates = []

FC_PORT_BASE = ".1.3.6.1.3.94"
FC_INDEX = "1.10.1.2"
FC_PORTTYPE = "1.10.1.3"
FC_ADMSTATE = "1.10.1.6"
FC_OPSTATE = "1.10.1.7"
FC_SPEED = "1.10.1.15"
FC_PORTNAME = "1.10.1.17"
FC_PHYSTATE = "1.10.1.23"
FC_TXOBJECTS = "4.5.1.4"
FC_RXOBJECTS = "4.5.1.5"
FC_TXELEMENTS = "4.5.1.6"
FC_RXELEMENTS = "4.5.1.7"
FC_NOTXCREDITS = "4.5.1.8"
FC_C3DISCARDS = "4.5.1.28"
FC_RXCRC = "4.5.1.40"
FC_RXENCOUTFRAMES = "4.5.1.50"

BROCADE_ENTERPRISE = ".1.3.6.1.4.1.1588.2.1.1"


def _snmp(ctx, community, host, oid):
    return ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)


def _snmpwalk(ctx, community, host, oid):
    return ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)


def _parse_octetstr(hexstr):
    parts = hexstr.strip().split()
    val = 0
    for p in parts:
        b = p
        if len(b) == 1:
            b = "0" + b
        val = val * 256 + int(b, 16)
    return val


def _to_int(txt):
    t = txt.strip()
    return int(t) if t.isdigit() else 0


def _walk_col(ctx, community, host, col_oid):
    out = {}
    res = _snmpwalk(ctx, community, host, FC_PORT_BASE + "." + col_oid)
    if res.rc != 0:
        return out
    base = FC_PORT_BASE + "." + col_oid
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid = sp[0]
        val = sp[1].strip()
        suffix = oid[len(base) + 1:]
        if suffix == "":
            continue
        out[suffix] = val
    return out


def _is_brocade_fc_switch(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = _snmp(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if res.rc != 0:
        return False
    sysoid = res.stdout.strip()
    return sysoid.startswith(BROCADE_ENTERPRISE)


def _discovery_rows(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    rows = {}
    idx_col = _walk_col(ctx, community, host, FC_INDEX)
    for idx, val in idx_col.items():
        rows[idx] = {"index": _to_int(val)}
    pt_col = _walk_col(ctx, community, host, FC_PORTTYPE)
    for idx, val in pt_col.items():
        if idx in rows:
            rows[idx]["porttype"] = _to_int(val)
    ad_col = _walk_col(ctx, community, host, FC_ADMSTATE)
    for idx, val in ad_col.items():
        if idx in rows:
            rows[idx]["admstate"] = _to_int(val)
    op_col = _walk_col(ctx, community, host, FC_OPSTATE)
    for idx, val in op_col.items():
        if idx in rows:
            rows[idx]["opstate"] = _to_int(val)
    ph_col = _walk_col(ctx, community, host, FC_PHYSTATE)
    for idx, val in ph_col.items():
        if idx in rows:
            rows[idx]["phystate"] = _to_int(val)
    pn_col = _walk_col(ctx, community, host, FC_PORTNAME)
    for idx, val in pn_col.items():
        if idx in rows:
            rows[idx]["portname"] = val.strip().strip('"')
    return rows


def _port_row(ctx, params, index):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    row = {}
    for col, name in [
        (FC_SPEED, "speed"),
        (FC_PORTNAME, "portname"),
    ]:
        res = _snmp(ctx, community, host, FC_PORT_BASE + "." + col + "." + str(index))
        if res.rc != 0:
            return None
        row[name] = res.stdout.strip()
    for col, name in [
        (FC_PORTTYPE, "porttype"),
        (FC_ADMSTATE, "admstate"),
        (FC_OPSTATE, "opstate"),
        (FC_PHYSTATE, "phystate"),
    ]:
        res = _snmp(ctx, community, host, FC_PORT_BASE + "." + col + "." + str(index))
        if res.rc != 0:
            return None
        row[name] = _to_int(res.stdout)
    for col, name in [
        (FC_TXOBJECTS, "txobjects"),
        (FC_RXOBJECTS, "rxobjects"),
        (FC_TXELEMENTS, "txelements"),
        (FC_RXELEMENTS, "rxelements"),
        (FC_NOTXCREDITS, "notxcredits"),
        (FC_C3DISCARDS, "c3discards"),
        (FC_RXCRC, "rxcrcs"),
        (FC_RXENCOUTFRAMES, "rxencoutframes"),
    ]:
        res = _snmp(ctx, community, host, FC_PORT_BASE + "." + col + "." + str(index))
        if res.rc != 0:
            return None
        row[name] = _parse_octetstr(res.stdout)
    return row


def _fmt_speed(speed_raw):
    s = speed_raw.strip()
    if s == "" or s == "0":
        return None, None
    digits = s.replace(".", "", 1)
    if not digits.isdigit():
        return None, None
    f = float(s)
    wirespeed = f * 1000.0 * 1000.0 * 1000.0 / 8.0
    speedmsg = "%f Gbit/s" % f
    return wirespeed, speedmsg


def _split_levels(lvl):
    if type(lvl) == "list" or type(lvl) == "tuple":
        return lvl[0], lvl[1]
    return lvl, None


def main(ctx, params):
    if params.get("_discover"):
        if not _is_brocade_fc_switch(ctx, params):
            return {
                "changed": False,
                "msg": "no Brocade/QLogic FC switch detected (wrong sysObjectID)",
                "data": {"discovery": []},
            }
        rows = _discovery_rows(ctx, params)
        n = len(rows)
        out = []
        for idx in sorted(rows.keys(), key=lambda x: int(x)):
            row = rows[idx]
            porttype = row.get("porttype", 0)
            admstate = row.get("admstate", 0)
            opstate = row.get("opstate", 0)
            phystate = row.get("phystate", 0)
            if porttype in fc_port_no_inventory_types:
                continue
            if admstate in fc_port_no_inventory_admstates:
                continue
            if opstate in fc_port_no_inventory_opstates:
                continue
            if phystate in fc_port_no_inventory_phystates:
                continue
            width = len(str(n))
            fmt = "%%0%dd" % width
            itemname = fmt % (int(idx) - 1)
            out.append({
                "item": itemname,
                "params": {
                    "rxcrcs": params.get("rxcrcs", (3.0, 20.0)),
                    "rxencoutframes": params.get("rxencoutframes", (3.0, 20.0)),
                    "notxcredits": params.get("notxcredits", (3.0, 20.0)),
                    "c3discards": params.get("c3discards", (3.0, 20.0)),
                },
                "metrics": [
                    "in_bytes", "out_bytes",
                    "rxobjects", "txobjects",
                    "rxcrcs", "rxencoutframes",
                    "c3discards", "notxcredits",
                ],
            })
        return {
            "changed": False,
            "msg": "discovered %d FC ports" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    parts = item.split()
    item_index = int(parts[0]) + 1 if (len(parts) > 0 and parts[0].isdigit()) else None
    if item_index == None:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not _is_brocade_fc_switch(ctx, params):
        return {
            "changed": False,
            "msg": "no Brocade/QLogic FC switch detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    portinfo = _port_row(ctx, params, item_index)
    if portinfo == None:
        return {
            "changed": False,
            "msg": "port %s not found in SNMP table" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    admstate = portinfo.get("admstate", 0)
    opstate = portinfo.get("opstate", 0)
    phystate = portinfo.get("phystate", 0)
    porttype = portinfo.get("porttype", 0)
    portname = portinfo.get("portname", "")

    speed_raw = portinfo.get("speed", "")
    wirespeed, speedmsg = _fmt_speed(speed_raw)
    if speedmsg == None:
        gbit = params.get("assumed_speed", 16.0)
        wirespeed = gbit * 1000.0 * 1000.0 * 1000.0 / 8.0
        speedmsg = "assuming %g Gbit/s" % gbit

    txobjects = portinfo.get("txobjects", 0)
    rxobjects = portinfo.get("rxobjects", 0)
    txelements = portinfo.get("txelements", 0)
    rxelements = portinfo.get("rxelements", 0)
    notxcredits = portinfo.get("notxcredits", 0)
    c3discards = portinfo.get("c3discards", 0)
    rxcrcs = portinfo.get("rxcrcs", 0)
    rxencoutframes = portinfo.get("rxencoutframes", 0)

    summarystate = 0
    output = [speedmsg]
    output.append("In: %s Bytes/s" % str(rxelements))
    output.append("Out: %s Bytes/s" % str(txelements))

    metrics = {
        "in_bytes": float(rxelements),
        "out_bytes": float(txelements),
        "rxobjects": float(rxobjects),
        "txobjects": float(txobjects),
    }

    for descr, counter, value, ref in [
        ("CRC errors", "rxcrcs", rxcrcs, rxobjects),
        ("ENC-Out", "rxencoutframes", rxencoutframes, rxobjects),
        ("C3 discards", "c3discards", c3discards, txobjects),
        ("no TX buffer credits", "notxcredits", notxcredits, txobjects),
    ]:
        per_sec = float(value)
        metrics[counter] = per_sec
        if ref > 0 or per_sec > 0:
            rate = per_sec / (float(ref) + per_sec)
        else:
            rate = 0.0
        error_percentage = rate * 100.0
        warn, crit = _split_levels(params.get(counter, (3.0, 20.0)))
        text = "%s: %f%%" % (descr, error_percentage)
        if crit != None and (error_percentage >= crit):
            summarystate = 2
            text = text + "(!!)"
            output.append(text)
        elif warn != None and (error_percentage >= warn):
            summarystate = max(1, summarystate)
            text = text + "(!)"
            output.append(text)

    adm_name = fc_port_admstates.get(admstate, "unknown")
    op_name = fc_port_opstates.get(opstate, "unknown")
    phy_name = fc_port_phystates.get(phystate, "unknown")
    ptype_name = porttype_list[porttype] if (0 <= porttype) and (porttype < len(porttype_list)) else "unknown"
    output.append("admstate=%s opstate=%s phystate=%s type=%s" % (
        adm_name, op_name, phy_name, ptype_name))

    if summarystate == 0:
        state = "OK"
    elif summarystate == 1:
        state = "WARN"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": "FC port %s: %s (%s)" % (item, ptype_name, "; ".join(output)),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "\n".join(output),
        },
    }