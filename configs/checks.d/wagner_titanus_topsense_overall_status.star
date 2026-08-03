# ===== check plugin: cmk/plugins/wagner/agent_based/wagner_titanus_topsense.py =====
# Translated from Checkmk check_plugin "wagner_titanus_topsense_overall_status"
# to a read-only Starlark check module.
#
# Source: SNMP section wagner_titanus_topsense
# Detect: sysObjectID equals .1.3.6.1.4.1.34187.21501 or .1.3.6.1.4.1.34187.74195
#
# The check reads the overall power-supply-failure status. It is a
# single-service check (no per-item breakdown). Discovery yields exactly
# one Service with item "".

# Base OIDs for the relevant SNMP trees.
SYS_OID = ".1.3.6.1.2.1.1"
MODEL_21501_OID = ".1.3.6.1.4.1.34187.21501.1.1"
MODEL_21501_STATUS_OID = ".1.3.6.1.4.1.34187.21501.2.1"
MODEL_74195_OID = ".1.3.6.1.4.1.34187.74195.1.1"
MODEL_74195_STATUS_OID = ".1.3.6.1.4.1.34187.74195.2.1"

# sysObjectID value to decide which model branch is active.
SYS_OID_OBJ = ".1.3.6.1.2.1.1.2.0"
MODEL_21501_ID = ".1.3.6.1.4.1.34187.21501"
MODEL_74195_ID = ".1.3.6.1.4.1.34187.74195"

# The PSW-failure indicator is the 10th value (index 9) of the model info
# row. For model 21501 it lives in tree .2.1; the value column index is 9.
# We discover which model is active via the sysObjectID, then read only the
# relevant status value.
MODEL_21501_LSN_OID = ".1.3.6.1.4.1.34187.21501.2.1.24584008"
# Fallback (no suffix) used only to validate presence; the real value is
# read from the model-appropriate LSN bus OID when available.

# OIDs for the model info row (base .1.1): 1,2,3,1000..1006
MODEL_INFO_COLS = ["1", "2", "3", "1000", "1001", "1002", "1003", "1004", "1005", "1006"]

# PSW failure is the 10th column (index 9) of the model info row.
# Its full OID is <model_base>.1.1006 ... but we read by column index below
# via a walk of the model info row base.
PSW_COL_INDEX = 9


def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpget is not installed on the host")
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpwalk is not installed on the host")
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        idx = line[:sp]
        val = line[sp + 1:]
        rows.append((idx, val))
    rows.sort()
    return rows


def _discover_model(ctx, community, host):
    sysoid = _snmp_get(ctx, community, host, SYS_OID_OBJ)
    if sysoid == None:
        return None
    if sysoid == MODEL_21501_ID:
        return "21501"
    if sysoid == MODEL_74195_ID:
        return "74195"
    return None


def _read_model_info_row(ctx, community, host, model):
    if model == "21501":
        base = MODEL_21501_OID
    else:
        base = MODEL_74195_OID
    rows = _snmp_walk(ctx, community, host, base)
    if len(rows) < len(MODEL_INFO_COLS):
        return None
    # rows are sorted by OID suffix; the first len(MODEL_INFO_COLS) rows
    # correspond to columns 1..1006 in order.
    values = []
    for i in range(len(MODEL_INFO_COLS)):
        values.append(rows[i][1])
    return values


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if params.get("_discover"):
        # PROBE FOR THE REAL THING FIRST.
        # Confirm the device is a Wagner Titus/Topsense unit by reading its
        # sysObjectID. Absence of snmpget or a non-matching sysObjectID means
        # this check does not apply here -> empty discovery.
        res_ver = _snmp_get(ctx, community, host, ".1.3.6.1.2.1.1.1.0")
        if res_ver == None:
            return {"changed": False, "msg": "device does not respond to SNMP",
                    "data": {"discovery": []}}
        sysoid = _snmp_get(ctx, community, host, SYS_OID_OBJ)
        if sysoid != MODEL_21501_ID and sysoid != MODEL_74195_ID:
            return {"changed": False,
                    "msg": "host is not a Wagner Topsense device",
                    "data": {"discovery": []}}
        model = _discover_model(ctx, community, host)
        if model == None:
            return {"changed": False,
                    "msg": "could not determine Topsense model",
                    "data": {"discovery": []}}
        # Single-service check: one Service with item "".
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "",
                     "params": {},
                     "metrics": []}
                ]}}

    # CHECK MODE (single service, item "").
    model = _discover_model(ctx, community, host)
    if model == None:
        return {"changed": False,
                "msg": "not a Wagner Topsense device (no matching sysObjectID)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    row = _read_model_info_row(ctx, community, host, model)
    if row == None or len(row) <= PSW_COL_INDEX:
        return {"changed": False,
                "msg": "could not read Topsense model info row",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    psw_failure = row[PSW_COL_INDEX]
    if psw_failure == "0":
        return {"changed": False, "msg": "Overall Status reports OK",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Overall Status reports a problem",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}}