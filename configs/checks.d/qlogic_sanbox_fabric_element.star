# Translated Checkmk check: qlogic_sanbox_fabric_element
# Source SNMP table: .1.3.6.1.2.1.75.1.1.4.1 (column .4) with OIDEnd index.
# Detection: sysObjectID startswith .1.3.6.1.4.1.3873.1.14 or .1.3.6.1.4.1.3873.1.8

def _sysoid(ctx, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _matches_vendor(sysoid):
    if sysoid.startswith(".1.3.6.1.4.1.3873.1.14"):
        return True
    if sysoid.startswith(".1.3.6.1.4.1.3873.1.8"):
        return True
    return False

def _fetch_table(ctx, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.75.1.1.4.1.4"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return []
    rows = []
    col_base = ".1.3.6.1.2.1.75.1.1.4.1.4"
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        if not oid.startswith(col_base + "."):
            continue
        idx = oid[len(col_base):]
        if idx.startswith("."):
            idx = idx[1:]
        rows.append({"index": idx, "status": val})
    return rows

def _lookup_status(ctx, community, host, index):
    col_oid = ".1.3.6.1.2.1.75.1.1.4.1.4." + index
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, col_oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _status_text(fe_id, fe_status):
    if fe_status == "1":
        return ("OK", "Fabric Element %s is online" % fe_id)
    elif fe_status == "2":
        return ("CRIT", "Fabric Element %s is offline" % fe_id)
    elif fe_status == "3":
        return ("WARN", "Fabric Element %s is testing" % fe_id)
    elif fe_status == "4":
        return ("CRIT", "Fabric Element %s is faulty" % fe_id)
    else:
        return ("UNKNOWN", "Fabric Element %s is in unidentified status %s" % (fe_id, fe_status))

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: the QLogic vendor sysObjectID.
    sysoid = _sysoid(ctx, community, host)
    if sysoid == "":
        return {
            "changed": False,
            "msg": "unable to read sysObjectID from host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not _matches_vendor(sysoid):
        # Not a QLogic SANbox switch — check does not apply.
        return {
            "changed": False,
            "msg": "host is not a QLogic SANbox fabric switch",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        rows = _fetch_table(ctx, community, host)
        discovery = []
        for r in rows:
            fe_id = r["status"]  # status column value used as identifier per source
            discovery.append({
                "item": r["index"],
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d fabric elements" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    rows = _fetch_table(ctx, community, host)
    for r in rows:
        if r["index"] == item:
            fe_status = r["status"]
            fe_id = item
            state, msg = _status_text(fe_id, fe_status)
            return {
                "changed": False,
                "msg": msg,
                "data": {"state": state, "metrics": {}, "details": ""},
            }

    return {
        "changed": False,
        "msg": "No Fabric Element %s found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }