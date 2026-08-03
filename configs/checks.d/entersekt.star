# Checkmk check: entersekt (Entersekt Server Status) translated to a
# read-only Starlark check module for the yolo-man agent.
#
# This is an SNMP-based Checkmk check. It monitors an Entersekt server via
# SNMP OIDs rooted at .1.3.6.1.4.1.38235.2. There are four logical sub-checks
# sharing one SNMP table fetch:
#   - entersekt            (status: running / not running)
#   - entersekt_emrerrors  (http EMR error count, upper levels)
#   - entersekt_ecerterrors(sgHttp Ecert error count, upper levels)
#   - entersekt_soaperrors (Soap service error count, upper levels)
#   - entersekt_certexpiry (days to next cert expiry, lower levels)
#
# The Starlark runtime has no Checkmk installed, so we query the same OIDs
# directly with net-snmp. Absence of the Entersekt enterprise OID means the
# product is not on this host -> empty discovery / UNKNOWN verdict.

# Metric/perfdata defaults (mirror Checkmk check_default_parameter).
DEFAULT_EMR_LEVELS = (100, 200)
DEFAULT_ECERT_LEVELS = (100, 200)
DEFAULT_SOAP_LEVELS = (100, 200)
DEFAULT_CERTEXPIRY_LEVELS = (20, 10)

# OID base and columns (from the SNMPTree in the source).
ENTERSEKT_BASE = ".1.3.6.1.4.1.38235.2"
OID_STATUS = ENTERSEKT_BASE + ".3.1.0"
OID_EMR_ERRORS = ENTERSEKT_BASE + ".3.4.0"
OID_ECERT_ERRORS = ENTERSEKT_BASE + ".3.8.0"
OID_SOAP_ERRORS = ENTERSEKT_BASE + ".3.9.0"
OID_CERT_EXPIRY = ENTERSEKT_BASE + ".17.1.0"

# SysDescr OID used for detection (contains "linux").
OID_SYSDESCR = ".1.3.6.1.2.1.1.1.0"

# Names of the logical sub-checks this single module exposes.
CHECK_STATUS = "entersekt"
CHECK_EMR = "entersekt_emrerrors"
CHECK_ECERT = "entersekt_ecerterrors"
CHECK_SOAP = "entersekt_soaperrors"
CHECK_CERT = "entersekt_certexpiry"


def _snmpget(ctx, oid):
    # Read-only SNMP GET returning the bare value (no type tag).
    # rc 127 -> snmpget not installed; rc 2/noOutput -> absent/timeout.
    return ctx.run(
        ["snmpget", "-v2c", "-c", ctx.params.get("community", "public"),
         "-Oqv", ctx.params.get("host", "localhost"), oid],
        mutates=False,
    )


def _fetch_entersekt(ctx):
    # Probe for the real Entersekt enterprise OID.
    res = _snmpget(ctx, OID_CERT_EXPIRY)
    # If the toolchain is missing or the host unreachable, we have no data.
    if res.rc != 0 or res.skipped or res.stdout == "":
        return None
    row = {}
    row["status"] = _snmpget(ctx, OID_STATUS).stdout.strip()
    row["emr_errors"] = _snmpget(ctx, OID_EMR_ERRORS).stdout.strip()
    row["ecert_errors"] = _snmpget(ctx, OID_ECERT_ERRORS).stdout.strip()
    row["soap_errors"] = _snmpget(ctx, OID_SOAP_ERRORS).stdout.strip()
    row["cert_expiry"] = res.stdout.strip()
    return row


def _detect(ctx):
    # Reproduce Checkmk's detect: sysDescr contains "linux" AND the Entersekt
    # enterprise OID exists.
    descr = _snmpget(ctx, OID_SYSDESCR)
    if descr.rc != 0 or descr.skipped or descr.stdout == "":
        return False
    if "linux" not in descr.stdout:
        return False
    probe = _snmpget(ctx, OID_CERT_EXPIRY)
    if probe.rc != 0 or probe.skipped or probe.stdout == "":
        return False
    return True


def main(ctx, params):
    ctx.params = params

    # --- DISCOVERY -------------------------------------------------------
    if params.get("_discover"):
        if not _detect(ctx):
            return {"changed": False, "msg": "no Entersekt server found",
                    "data": {"discovery": []}}
        items = [
            {"item": "", "params": {}, "metrics": ["status"]},
            {"item": "", "params": {"levels": list(DEFAULT_EMR_LEVELS)},
             "metrics": ["emr_errors"]},
            {"item": "",
             "params": {"levels": list(DEFAULT_ECERT_LEVELS)},
             "metrics": ["ecert_errors"]},
            {"item": "", "params": {"levels": list(DEFAULT_SOAP_LEVELS)},
             "metrics": ["soap_errors"]},
            {"item": "",
             "params": {"levels": list(DEFAULT_CERTEXPIRY_LEVELS)},
             "metrics": ["cert_expiry"]},
        ]
        return {"changed": False,
                "msg": "discovered %d Entersekt services" % len(items),
                "data": {"discovery": items}}

    # --- CHECK MODE ------------------------------------------------------
    check = params.get("item", "entersekt")

    if not _detect(ctx):
        return {"changed": False, "msg": "no Entersekt server found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    row = _fetch_entersekt(ctx)
    if row == None:
        return {"changed": False, "msg": "Entersekt SNMP data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if check == CHECK_STATUS:
        running = row["status"] == "true"
        if running:
            return {"changed": False, "msg": "Server is running",
                    "data": {"state": "OK", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "Server is NOT running",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    if check == CHECK_EMR:
        levels = params.get("levels", list(DEFAULT_EMR_LEVELS))
        warn = levels[0] if len(levels) > 0 else DEFAULT_EMR_LEVELS[0]
        crit = levels[1] if len(levels) > 1 else DEFAULT_EMR_LEVELS[1]
        val = 0
        raw = row["emr_errors"]
        if raw.isdigit():
            val = int(raw)
        if val > crit:
            state = "CRIT"
            s = "Number of errors is %d which is higher than %d" % (val, crit)
        elif val > warn:
            state = "WARN"
            s = "Number of errors is %d which is higher than %d" % (val, warn)
        else:
            state = "OK"
            s = "Number of errors is %d" % val
        return {"changed": False, "msg": s,
                "data": {"state": state, "metrics": {"emr_errors": val},
                         "details": ""}}

    if check == CHECK_ECERT:
        levels = params.get("levels", list(DEFAULT_ECERT_LEVELS))
        warn = levels[0] if len(levels) > 0 else DEFAULT_ECERT_LEVELS[0]
        crit = levels[1] if len(levels) > 1 else DEFAULT_ECERT_LEVELS[1]
        val = 0
        raw = row["ecert_errors"]
        if raw.isdigit():
            val = int(raw)
        if val > crit:
            state = "CRIT"
            s = "Number of errors is %d which is higher than %d" % (val, crit)
        elif val > warn:
            state = "WARN"
            s = "Number of errors is %d which is higher than %d" % (val, warn)
        else:
            state = "OK"
            s = "Number of errors is %d" % val
        return {"changed": False, "msg": s,
                "data": {"state": state, "metrics": {"ecert_errors": val},
                         "details": ""}}

    if check == CHECK_SOAP:
        levels = params.get("levels", list(DEFAULT_SOAP_LEVELS))
        warn = levels[0] if len(levels) > 0 else DEFAULT_SOAP_LEVELS[0]
        crit = levels[1] if len(levels) > 1 else DEFAULT_SOAP_LEVELS[1]
        val = 0
        raw = row["soap_errors"]
        if raw.isdigit():
            val = int(raw)
        if val > crit:
            state = "CRIT"
            s = "Number of errors is %d which is higher than %d" % (val, crit)
        elif val > warn:
            state = "WARN"
            s = "Number of errors is %d which is higher than %d" % (val, warn)
        else:
            state = "OK"
            s = "Number of errors is %d" % val
        return {"changed": False, "msg": s,
                "data": {"state": state, "metrics": {"soap_errors": val},
                         "details": ""}}

    if check == CHECK_CERT:
        levels = params.get("levels", list(DEFAULT_CERTEXPIRY_LEVELS))
        # Lower levels: warn first in the tuple (20), crit second (10).
        warn = levels[0] if len(levels) > 0 else DEFAULT_CERTEXPIRY_LEVELS[0]
        crit = levels[1] if len(levels) > 1 else DEFAULT_CERTEXPIRY_LEVELS[1]
        val = 0
        raw = row["cert_expiry"]
        if raw.isdigit():
            val = int(raw)
        if val < crit:
            state = "CRIT"
            s = "Number of days until expiration is %d which is less than %d" % (val, crit)
        elif val < warn:
            state = "WARN"
            s = "Number of days until expiration is %d which is less than %d" % (val, warn)
        else:
            state = "OK"
            s = "Number of days is %d" % val
        return {"changed": False, "msg": s,
                "data": {"state": state, "metrics": {"cert_expiry": val},
                         "details": ""}}

    return {"changed": False, "msg": "unknown Entersekt sub-check: " + str(check),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}