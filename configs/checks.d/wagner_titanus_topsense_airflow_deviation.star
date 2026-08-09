# Translated Checkmk check: wagner_titanus_topsense_airflow_deviation
# Read-only Starlark check module. Monitors air-flow deviation (%). Upper/lower levels.

# Defaults from the Checkmk source check_default_parameters.
DEFAULT_UPPER = (20.0, 20.0)
DEFAULT_LOWER = (-20.0, -20.0)

# SNMP OIDs for this device family (Wagner Titus Topsense).
SYS_OID = ".1.3.6.1.2.1.1"
MODEL_OID_A = ".1.3.6.1.4.1.34187.21501.1.1"
MODEL_OIDS = ["1", "2", "3", "1000", "1001", "1002", "1003", "1004", "1005", "1006"]
MEASUREMENT_OID_A = ".1.3.6.1.4.1.34187.21501.2.1"
MEASUREMENT_OIDS_A = [
    "245810000", "245820000", "245950000", "246090000",
    "245960000", "246100000", "245970000", "246110000", "24584008",
]
MODEL_OID_B = ".1.3.6.1.4.1.34187.74195.1.1"
MEASUREMENT_OID_B = ".1.3.6.1.4.1.34187.74195.2.1"
MEASUREMENT_OIDS_B = [
    "245790000", "245800000", "245940000", "246060000",
    "245950000", "246070000", "245960000", "246080000",
]

# sysoid values this check detects.
SYSOID_A = ".1.3.6.1.4.1.34187.21501"
SYSOID_B = ".1.3.6.1.4.1.34187.74195"


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _get_sysinfo(ctx, host, community):
    # sysDescr (1.1), sysName (1.3), sysContact (1.4), sysLocation (1.5).
    descr = _snmp_get(ctx, host, community, SYS_OID + ".1")
    name = _snmp_get(ctx, host, community, SYS_OID + ".3")
    contact = _snmp_get(ctx, host, community, SYS_OID + ".4")
    location = _snmp_get(ctx, host, community, SYS_OID + ".5")
    return [descr, name, contact, location]


def _get_model_data(ctx, host, community, sysoid):
    # Returns [sysrow, modelrow, measurerow] using the model matching the sysoid.
    sysrow = _get_sysinfo(ctx, host, community)
    if sysoid == SYSOID_A:
        model_base = MODEL_OID_A
        meas_base = MEASUREMENT_OID_A
        meas_oids = MEASUREMENT_OIDS_A
    else:
        model_base = MODEL_OID_B
        meas_base = MEASUREMENT_OID_B
        meas_oids = MEASUREMENT_OIDS_B

    model_vals = []
    for oid_suffix in MODEL_OIDS:
        v = _snmp_get(ctx, host, community, model_base + "." + oid_suffix)
        if v == None:
            return None
        model_vals.append(v)

    meas_vals = []
    for oid_suffix in meas_oids:
        v = _snmp_get(ctx, host, community, meas_base + "." + oid_suffix)
        if v == None:
            return None
        meas_vals.append(v)

    return [sysrow, model_vals, meas_vals]


def _detect(ctx, host, community):
    # Probe for the real device by reading sysOID; missing means not present.
    sysoid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sysoid == None:
        return None
    if sysoid == SYSOID_A:
        return sysoid
    if sysoid == SYSOID_B:
        return sysoid
    return None


def _fmt(v):
    if v == None:
        return "unknown"
    return str(v)


def _to_float(v):
    if v == None:
        return None
    s = str(v)
    return float(s)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    levels_upper = params.get("levels_upper", list(DEFAULT_UPPER))
    levels_lower = params.get("levels_lower", list(DEFAULT_LOWER))

    if params.get("_discover"):
        sysoid = _detect(ctx, host, community)
        if sysoid == None:
            return {
                "changed": False,
                "msg": "no Wagner Titus Topsense device found",
                "data": {"discovery": []},
            }
        discovery = []
        for i in ["1", "2"]:
            discovery.append({
                "item": i,
                "params": {
                    "levels_upper": levels_upper,
                    "levels_lower": levels_lower,
                },
                "metrics": ["airflow_deviation"],
                "service_labels": {"sysoid": _fmt(sysoid)},
            })
        return {
            "changed": False,
            "msg": "discovered %d airflow deviation detectors" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {"cmk/snmp": "true"}},
        }

    sysoid = _detect(ctx, host, community)
    if sysoid == None:
        return {
            "changed": False,
            "msg": "no Wagner Titus Topsense device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parsed = _get_model_data(ctx, host, community, sysoid)
    if parsed == None:
        return {
            "changed": False,
            "msg": "failed to retrieve model/measurement data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    meas = parsed[2]
    # airflow deviation column index is the same for both models.
    if item == "1":
        idx = 4
    elif item == "2":
        idx = 5
    else:
        return {
            "changed": False,
            "msg": "Airflow Deviation Detector %s not found" % _fmt(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if idx >= len(meas):
        return {
            "changed": False,
            "msg": "no airflow deviation value for detector %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = meas[idx]
    airflow_deviation = _to_float(raw)
    if airflow_deviation == None:
        return {
            "changed": False,
            "msg": "invalid airflow deviation value: %s" % _fmt(raw),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Upper levels: warn if >= warn, crit if >= crit.
    # Lower levels: warn if <= warn, crit if <= crit.
    state = "OK"
    w_upper = levels_upper[0]
    c_upper = levels_upper[1]
    w_lower = levels_lower[0]
    c_lower = levels_lower[1]

    if (airflow_deviation >= c_upper) or (airflow_deviation <= c_lower):
        state = "CRIT"
    elif (airflow_deviation >= w_upper) or (airflow_deviation <= w_lower):
        state = "WARN"

    return {
        "changed": False,
        "msg": "%f%% Airflow Deviation" % airflow_deviation,
        "data": {
            "state": state,
            "metrics": {"airflow_deviation": airflow_deviation},
            "details": "levels_upper=%s levels_lower=%s" % (
                _fmt(levels_upper), _fmt(levels_lower)),
        },
    }