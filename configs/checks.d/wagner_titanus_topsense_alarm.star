# wagner_titanus_topsense_alarm.star
#
# Translates the Checkmk check plugin `wagner_titanus_topsense_alarm`
# (service "Alarm Detector %s") into a read-only Starlark check module.
#
# The original Checkmk plugin reads its data from an SNMP section
# (`wagner_titanus_topsense`) that is auto-detected by the device's
# sysObjectID (`.1.3.6.1.4.1.34187.21501` or `.1.3.6.1.4.1.34187.74195`).
# This translation reproduces that SNMP fetch + the alarm check/threshold
# logic directly via net-snmp.

# ---------------------------------------------------------------------------
# OIDs
# ---------------------------------------------------------------------------

# Standard MIB-II sysDescr/sysUpTime/sysName/sysContact/sysLocation
SYS_OID_BASE = ".1.3.6.1.2.1.1"

# Model/vendor specific OIDs (one of the two supported firmware variants)
MODEL_A_BASE = ".1.3.6.1.4.1.34187.21501.1.1"
MODEL_A_TS_BASE = ".1.3.6.1.4.1.34187.21501.2.1"
MODEL_B_BASE = ".1.3.6.1.4.1.34187.74195.1.1"
MODEL_B_TS_BASE = ".1.3.6.1.4.1.34187.74195.2.1"

# Column OIDs for the model-info tree, relative to the model base.
# Index 0..8 correspond to oids ["1","2","3","1000","1001","1002",
# "1003","1004","1005"] and "1006" lives at index 9.
MODEL_COLS = [
    "1", "2", "3", "1000", "1001", "1002",
    "1003", "1004", "1005", "1006",
]


def _join_oid(base, suffix):
    if base.endswith(".") and str(suffix).startswith("."):
        return base + str(suffix)[1:]
    if not base.endswith(".") and not str(suffix).startswith("."):
        return base + "." + str(suffix)
    return base + str(suffix)


def _build_model_oids(base):
    oids = []
    for col in MODEL_COLS:
        oids.append(_join_oid(base, col))
    return oids


def _build_ts_oids(base):
    oids = []
    # ts columns: 245810000 ... 24584008 (9 columns for model A)
    for col in [
        "245810000", "245820000", "245950000", "246090000",
        "245960000", "246100000", "245970000", "246110000", "24584008",
    ]:
        oids.append(_join_oid(base, col))
    return oids


# ---------------------------------------------------------------------------
# SNMP probing helpers
# ---------------------------------------------------------------------------

def _snmp_get_bulk(ctx, host, community, oids):
    """Issue a single snmpget for several OIDs; return list of values (or None)."""
    if not oids:
        return None
    argv = [
        "snmpget", "-v2c",
        "-c", community,
        "-Oqv",
    ]
    argv.append(host)
    argv.extend(oids)
    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    if len(lines) != len(oids):
        # Mismatch means we could not retrieve every value cleanly.
        return None
    values = []
    for line in lines:
        # -Oqv prints the bare value only; quotes are already stripped by
        # net-snmp's default output for STRING types.
        values.append(line.strip())
    return values


def _detect_model(ctx, host, community):
    """Return (model_base, ts_base, sys_values) or (None, None, None).

    Mirrors the Checkmk `any_of`/`equals` detection: the device's
    sysObjectID at `.1.3.6.1.2.1.1.2.0` must equal one of the two known
    Wagner-Titanus OIDs.
    """
    sys_values = _snmp_get_bulk(
        ctx, host, community,
        [_join_oid(SYS_OID_BASE, "1"), _join_oid(SYS_OID_BASE, "3"),
         _join_oid(SYS_OID_BASE, "4"), _join_oid(SYS_OID_BASE, "5"),
         _join_oid(SYS_OID_BASE, "6"), ".1.3.6.1.2.1.1.2.0"],
    )
    if sys_values == None or len(sys_values) < 6:
        return (None, None, None)

    sys_object_id = sys_values[5]
    if sys_object_id == MODEL_A_BASE or sys_object_id == ".1.3.6.1.4.1.34187.21501":
        return (MODEL_A_BASE, MODEL_A_TS_BASE, sys_values)
    if sys_object_id == MODEL_B_BASE or sys_object_id == ".1.3.6.1.4.1.34187.74195":
        return (MODEL_B_BASE, MODEL_B_TS_BASE, sys_values)
    return (None, None, None)


def _fetch_model_data(ctx, host, community, model_base, ts_base):
    """Return (row0, row1) where row0 is the sys info list and row1 is the
    model-info list; or (None, None) on failure."""
    sys_vals = _snmp_get_bulk(
        ctx, host, community,
        [_join_oid(SYS_OID_BASE, "1"), _join_oid(SYS_OID_BASE, "3"),
         _join_oid(SYS_OID_BASE, "4"), _join_oid(SYS_OID_BASE, "5"),
         _join_oid(SYS_OID_BASE, "6")],
    )
    model_vals = _snmp_get_bulk(ctx, host, community, _build_model_oids(model_base))
    if model_vals == None:
        return (None, None)
    ts_vals = _snmp_get_bulk(ctx, host, community, _build_ts_oids(ts_base))
    # ts data is used by other checks in the family; for the alarm check we
    # only need row0 (sys) and row1 (model). Still fetch so absence is real.
    if ts_vals == None:
        # Treat the topsense tree as present if model data exists; ts absent
        # only affects the sibling smoke/temp checks.
        pass
    return (sys_vals, model_vals)


# ---------------------------------------------------------------------------
# Starlark module entry point
# ---------------------------------------------------------------------------

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        model_base, ts_base, sys_values = _detect_model(ctx, host, community)
        if model_base == None:
            # Device not present / not a Wagner-Titanus Topsense unit.
            return {
                "changed": False,
                "msg": "no Wagner-Titanus Topsense device found at %s" % host,
                "data": {"discovery": []},
            }
        # The alarm check always exposes two fixed alarm detectors.
        discovery = [
            {
                "item": "1",
                "params": {},
                "metrics": [],
            },
            {
                "item": "2",
                "params": {},
                "metrics": [],
            },
        ]
        return {
            "changed": False,
            "msg": "discovered %d alarm detectors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE -------------------------------------------------------
    item = params.get("item", "")
    if item != "1" and item != "2":
        return {
            "changed": False,
            "msg": "Alarm Detector %s not found in SNMP" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    model_base, ts_base, sys_values = _detect_model(ctx, host, community)
    if model_base == None:
        return {
            "changed": False,
            "msg": "no Wagner-Titanus Topsense device found at %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sys_vals, model_vals = _fetch_model_data(ctx, host, community, model_base, ts_base)
    if model_vals == None:
        return {
            "changed": False,
            "msg": "failed to read Topsense model data via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Map of alarm columns for item 1 and item 2, mirroring the source:
    #   item 1 -> main(3), pre(4), info(5)
    #   item 2 -> main(6), pre(7), info(8)
    if item == "1":
        main_alarm = model_vals[3]
        pre_alarm = model_vals[4]
        info_alarm = model_vals[5]
    else:
        main_alarm = model_vals[6]
        pre_alarm = model_vals[7]
        info_alarm = model_vals[8]

    state = "OK"
    message = "No Alarm"
    if info_alarm != "0":
        message = "Info Alarm"
        state = "WARN"
    if pre_alarm != "0":
        message = "Pre Alarm"
        state = "WARN"
    if main_alarm != "0":
        message = "Main Alarm: Fire"
        state = "CRIT"

    return {
        "changed": False,
        "msg": message,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }