def main(ctx, params):
    # SNMP base and OIDs from Checkmk source
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.38235.2"
    # OIDs: .3.1.0=server_running, .3.4.0=http_emr_errors, .3.8.0=ecert_errors, .3.9.0=soap_errors, .17.1.0=cert_days

    # Fetch all relevant SNMP data in one walk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".3.1.0", base_oid + ".3.4.0", base_oid + ".3.8.0", base_oid + ".3.9.0", base_oid + ".17.1.0"
    ], mutates=False)

    # Parse SNMP output lines: "<oid> = <type>: <value>"
    values = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        # Extract numeric OID suffix for known base OIDs
        suffix = None
        if oid_part.endswith(".3.1.0"):
            suffix = "server_running"
        elif oid_part.endswith(".3.4.0"):
            suffix = "http_emr_errors"
        elif oid_part.endswith(".3.8.0"):
            suffix = "ecert_errors"
        elif oid_part.endswith(".3.9.0"):
            suffix = "soap_errors"
        elif oid_part.endswith(".17.1.0"):
            suffix = "cert_days"
        if suffix != None:
            # Extract value after ": "
            val_str = value_part.split(": ")
            if len(val_str) >= 2:
                values[suffix] = val_str[1].strip()

    # Discovery mode
    if params.get("_discover"):
        if "server_running" in values or "http_emr_errors" in values or "ecert_errors" in values or "soap_errors" in values or "cert_days" in values:
            return {
                "changed": False,
                "msg": "discovered Entersekt service",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": (100, 200)}, "metrics": ["Errors"]}
                ]},
            }
        else:
            return {
                "changed": False,
                "msg": "no Entersekt data available",
                "data": {"discovery": []},
            }

    # Check mode for soaperrors
    soap_errors_str = values.get("soap_errors", "")
    soap_errors = 0
    if soap_errors_str != "" and soap_errors_str.isdigit():
        soap_errors = int(soap_errors_str)

    levels = params.get("levels", (100, 200))
    warn = levels[0]
    crit = levels[1]

    if soap_errors >= crit:
        state = "CRIT"
        msg = "Number of errors is %d which is higher than %d" % (soap_errors, crit)
    elif soap_errors >= warn:
        state = "WARN"
        msg = "Number of errors is %d which is higher than %d" % (soap_errors, warn)
    else:
        state = "OK"
        msg = "Number of errors is %d" % soap_errors

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"Errors": soap_errors},
            "details": "",
        },
    }
