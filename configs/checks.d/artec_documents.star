# artec_documents — Checkmk check translation (read-only Starlark check module)
#
# Source: Checkmk checkmk.artec_documents (SimpleSNMPSection + SNMPTree)
# SNMP base OID: .1.3.6.1.4.1.31560.0.0.3.1
#   column 3 (artecDocumentsName)   -> .1.3.6.1.4.1.31560.0.0.3.1.3  (doc name strings)
#   column 1 (artecDocumentsValues) -> .1.3.6.1.4.1.31560.0.0.3.1.1  (doc counts)
# Detection: sysObjectID == .1.3.6.1.4.1.8072.3.2.10  AND  sysDescr contains "version" and "serial"
#
# Discovery yields a single Service("Documents") (item "") with metrics derived from the
# name/value rows. Per original check semantics: one row per (name, value) pair; rate is a
# derived perfdata value computed from consecutive samples within a single check invocation.

ARTEC_NAME_OID = ".1.3.6.1.4.1.31560.0.0.3.1.3"
ARTEC_VALUE_OID = ".1.3.6.1.4.1.31560.0.0.3.1.1"
SYSOID_OID = ".1.3.6.1.2.1.1.2.0"
SYSDESC_OID = ".1.3.6.1.2.1.1.1.0"
EXPECTED_SYSOID = ".1.3.6.1.4.1.8072.3.2.10"

# module-level metric name -> display label map (defined at top level per Starlark rules)
METRIC_MAP = {}


def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            return ""
        if res.stdout == "":
            return ""
        return ""
    return res.stdout.strip()


def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            return []
        return []
    rows = []
    for line in res.stdout.splitlines():
        if line == "":
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:].strip()
        rows.append((full_oid, value))
    return rows


def _detect_artec(ctx, community, host):
    sysid = _snmp_get(ctx, community, host, SYSOID_OID)
    if sysid == "":
        return False
    # ARTEC-MIB::artecDocumentsName uses enterprise OID prefix; match exact sysObjectID
    if sysid != EXPECTED_SYSOID:
        return False
    desc = _snmp_get(ctx, community, host, SYSDESC_OID)
    if desc == "":
        return False
    if "version" not in desc:
        return False
    if "serial" not in desc:
        return False
    return True


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # ---- DISCOVERY MODE ----
        if not _detect_artec(ctx, community, host):
            return {"changed": False, "msg": "host is not an ArTec device",
                    "data": {"discovery": []}}
        names = _snmp_walk(ctx, community, host, ARTEC_NAME_OID)
        values = _snmp_walk(ctx, community, host, ARTEC_VALUE_OID)
        # build index -> value map from the values column
        val_by_idx = {}
        for vfull, vval in values:
            vsuffix = vfull[len(ARTEC_VALUE_OID) + 1:]
            val_by_idx[vsuffix] = vval
        metric_names = []
        found = False
        for nfull, nval in named_rows(names):
            idx = nfull[len(ARTEC_NAME_OID) + 1:]
            if idx not in val_by_idx:
                continue
            doc_val = val_by_idx[idx]
            if doc_val == "":
                continue
            doc_int = int(doc_val) if doc_val.lstrip("-").isdigit() else 0
            # rate metric per original check: derived perfdata "rate_<doc_name>"
            mname = "rate_" + _clean_name(nval)
            metric_names.append(mname)
            found = True
        if not found:
            return {"changed": False, "msg": "no artec document rows found",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered Documents service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": metric_names}
                ]}}

    # ---- CHECK MODE ----
    if not _detect_artec(ctx, community, host):
        return {"changed": False, "msg": "host is not an ArTec device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    names = _snmp_walk(ctx, community, host, ARTEC_NAME_OID)
    values = _snmp_walk(ctx, community, host, ARTEC_VALUE_OID)
    if len(names) == 0 and len(values) == 0:
        return {"changed": False, "msg": "no artec document data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val_by_idx = {}
    for vfull, vval in values:
        vsuffix = vfull[len(ARTEC_VALUE_OID) + 1:]
        val_by_idx[vsuffix] = vval
    now = ctx.run(["date", "+%s"], mutates=False)
    ts = 0
    if now.stdout != "":
        ts = int(now.stdout.strip()) if now.stdout.strip().isdigit() else 0
    summary_parts = []
    metrics = {}
    for nfull, nval in named_rows(names):
        idx = nfull[len(ARTEC_NAME_OID) + 1:]
        doc_val = val_by_idx.get(idx, "")
        if doc_val == "":
            continue
        doc_int = int(doc_val) if doc_val.lstrip("-").isdigit() else 0
        name = _clean_name(nval)
        # rate is a derived value; with only a single sample we report the count as the value
        metrics["rate_" + name] = float(doc_int)
        summary_parts.append("%s: %d" % (name, doc_int))
    if len(summary_parts) == 0:
        return {"changed": False, "msg": "no artec document values found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "; ".join(summary_parts),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}


def named_rows(rows):
    out = []
    for full, val in rows:
        out.append((full, val))
    return out


def _clean_name(raw):
    n = raw.replace("Count", "").replace("count", "").strip()
    return n if n != "" else raw