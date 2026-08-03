# Wagner Titanus Topsense smoke detector (and related) SNMP check
# Translated from Checkmk plugin: wagner_titanus_topsense
# This module reproduces discovery + the smoke detector check logic.

# SNMP OIDs for the two possible models identified by sysObjectID.
# Model A (21501): column OIDs under .1.3.6.1.4.1.34187.21501
# Model B (74195): column OIDs under .1.3.6.1.4.1.34187.74195
SYS_OID_BASE = ".1.3.6.1.2.1.1.2.0"
MODEL_A_SYS = ".1.3.6.1.4.1.34187.21501"
MODEL_B_SYS = ".1.3.6.1.4.1.34187.74195"

# sysDescr / sysObjectID / sysContact / sysName / sysLocation
SYS_INFO_BASE = ".1.3.6.1.2.1.1"
# Device-specific: company/model/revision
MODEL_A_DEV_BASE = ".1.3.6.1.4.1.34187.21501.1.1"
# Device measurement columns
MODEL_A_MEAS_BASE = ".1.3.6.1.4.1.34187.21501.2.1"
MODEL_B_DEV_BASE = ".1.3.6.1.4.1.34187.74195.1.1"
MODEL_B_MEAS_BASE = ".1.3.6.1.4.1.34187.74195.2.1"

# OID suffix for sysDescr within SYS_INFO_BASE
SYS_OID_SUFFIX = "1"
SYS_CONTACT_SUFFIX = "2"
SYS_NAME_SUFFIX = "4"
SYS_LOCATION_SUFFIX = "6"

# Measurement column OID suffixes (relative to model dev base)
SMOKE_COL_1 = "245810000"
SMOKE_COL_2 = "245820000"
CHAMBER_DEV_1 = "245950000"
CHAMBER_DEV_2 = "246090000"
AIRFLOW_DEV_1 = "245960000"
AIRFLOW_DEV_2 = "246100000"
TEMP_AMB1 = "245970000"
TEMP_AMB2 = "246110000"

# Model B measurement column OID suffixes
SMOKE_COL_1_B = "245790000"
SMOKE_COL_2_B = "245800000"

# Company/model/revision OIDs within device base
COMPANY_OID = "1"
MODEL_OID = "2"
REVISION_OID = "3"
PSW_FAILURE_OID = "1006"

# Smoke thresholds (percent).
SMOKE_WARN = 3.0
SMOKE_CRIT = 5.0


def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpget not available on the monitoring host")
    if res.rc != 0:
        return ""
    return res.stdout.rstrip("\n")


def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpwalk not available on the monitoring host")
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        # Format: <OID> <value>
        parts = line.split(" ", 1)
        if len(parts) == 2:
            lines.append((parts[0], parts[1]))
    return lines


def _get_model_data(ctx, community, host, sys_oid):
    # Fetch sys-level info (sysoid, sysuptime, syscontact, sysname, syslocation)
    sysoid = _snmp_get(ctx, community, host, SYS_INFO_BASE + "." + SYS_OID_SUFFIX)
    sysuptime = _snmp_get(ctx, community, host, SYS_INFO_BASE + "." + "3")
    syscontact = _snmp_get(ctx, community, host, SYS_INFO_BASE + "." + SYS_CONTACT_SUFFIX)
    sysname = _snmp_get(ctx, community, host, SYS_INFO_BASE + "." + SYS_NAME_SUFFIX)
    syslocation = _snmp_get(ctx, community, host, SYS_INFO_BASE + "." + SYS_LOCATION_SUFFIX)
    sys_info = [sysoid, sysuptime, syscontact, sysname, syslocation]

    if sys_oid == MODEL_A_SYS:
        dev_base = MODEL_A_DEV_BASE
        meas_base = MODEL_A_MEAS_BASE
    else:
        dev_base = MODEL_B_DEV_BASE
        meas_base = MODEL_B_MEAS_BASE

    company = _snmp_get(ctx, community, host, dev_base + "." + COMPANY_OID)
    model = _snmp_get(ctx, community, host, dev_base + "." + MODEL_OID)
    revision = _snmp_get(ctx, community, host, dev_base + "." + REVISION_OID)
    psw_failure = _snmp_get(ctx, community, host, dev_base + "." + PSW_FAILURE_OID)
    dev_info = [company, model, revision, psw_failure]

    # Measurement columns
    smoke1 = _snmp_get(ctx, community, host, meas_base + "." + SMOKE_COL_1)
    smoke2 = _snmp_get(ctx, community, host, meas_base + "." + SMOKE_COL_2)
    chamber_dev1 = _snmp_get(ctx, community, host, meas_base + "." + CHAMBER_DEV_1)
    chamber_dev2 = _snmp_get(ctx, community, host, meas_base + "." + CHAMBER_DEV_2)
    airflow_dev1 = _snmp_get(ctx, community, host, meas_base + "." + AIRFLOW_DEV_1)
    airflow_dev2 = _snmp_get(ctx, community, host, meas_base + "." + AIRFLOW_DEV_2)
    temp_amb1 = _snmp_get(ctx, community, host, meas_base + "." + TEMP_AMB1)
    temp_amb2 = _snmp_get(ctx, community, host, meas_base + "." + TEMP_AMB2)
    # LSNi bus (only present on model A)
    lsn_bus = _snmp_get(ctx, community, host, meas_base + "." + "24584008")

    meas_info = [
        smoke1, smoke2, chamber_dev1, chamber_dev2,
        airflow_dev1, airflow_dev2, temp_amb1, temp_amb2, lsn_bus,
    ]

    return [sys_info, dev_info, meas_info]


def _get_sys_oid(ctx, community, host):
    sysoid = _snmp_get(ctx, community, host, SYS_OID_BASE)
    if sysoid == MODEL_A_SYS or sysoid == MODEL_B_SYS:
        return sysoid
    return ""


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery: enumerate one per detector for smoke
        sys_oid = _get_sys_oid(ctx, community, host)
        if sys_oid == "":
            return {
                "changed": False,
                "msg": "device is not a Wagner Topsense smoke detector",
                "data": {"discovery": []},
            }
        discovered = [
            {"item": "1", "params": {"warn": SMOKE_WARN, "crit": SMOKE_CRIT},
             "metrics": ["smoke_perc"]},
            {"item": "2", "params": {"warn": SMOKE_WARN, "crit": SMOKE_CRIT},
             "metrics": ["smoke_perc"]},
        ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode: check one smoke detector item
    item = params.get("item", "")
    sys_oid = _get_sys_oid(ctx, community, host)
    if sys_oid == "":
        return {
            "changed": False,
            "msg": "device is not a Wagner Topsense smoke detector",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parsed = _get_model_data(ctx, community, host, sys_oid)
    # parsed[2] is the measurement list
    meas = parsed[2]

    if item == "1":
        smoke_val = meas[0]
    elif item == "2":
        smoke_val = meas[1]
    else:
        return {
            "changed": False,
            "msg": "Smoke Detector %s not found in SNMP" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if smoke_val == "":
        return {
            "changed": False,
            "msg": "no smoke reading for detector %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    smoke_perc = float(smoke_val)
    warn = params.get("warn", SMOKE_WARN)
    crit = params.get("crit", SMOKE_CRIT)
    if smoke_perc > crit:
        state = "CRIT"
    elif smoke_perc > warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "%f%% smoke detected" % smoke_perc,
        "data": {
            "state": state,
            "metrics": {"smoke_perc": smoke_perc},
            "details": "",
        },
    }