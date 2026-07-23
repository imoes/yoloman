def main(ctx, params):
    # SNMP OIDs for the Entersekt MIB section
    base_oid = ".1.3.6.1.4.1.38235.2"
    server_running_oid = base_oid + ".3.1.0"
    emr_errors_oid = base_oid + ".3.4.0"
    ecert_errors_oid = base_oid + ".3.8.0"
    soap_errors_oid = base_oid + ".3.9.0"
    cert_days_oid = base_oid + ".3.17.1.0"

    # Helper to extract value from snmpget output
    def get_snmp_value(oid):
        # Use snmpget for scalar OID to get single value
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), 
                      "-On", params.get("host", "localhost"), oid], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return None
        # Parse: ".1.3.6.1.4.1.38235.2.3.1.0 = STRING: "true"
        line = res.stdout.strip()
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            return None
        value_part = parts[1]
        # Handle different types: STRING:, INTEGER:, etc.
        if value_part.startswith("STRING: "):
            return value_part[8:]  # Remove "STRING: "
        elif value_part.startswith("INTEGER: "):
            return int(value_part[9:])
        else:
            # For other types, try to extract numeric or string
            return value_part.strip()

    # Check if the agent_section exists (detect logic)
    # Checkmk detection: all_of(contains(".1.3.6.1.2.1.1.1.0", "linux"), exists(".1.3.6.1.4.1.38235.2.3.1.0"))
    # For discovery, we'll check if the first OID exists and we can read it

    if params.get("_discover"):
        server_running = get_snmp_value(server_running_oid)
        if server_running != None:
            # Return a single-service discovery (one service for this host)
            return {
                "changed": False,
                "msg": "discovered Entersekt services",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": ["server_status"]},
                    ],
                },
            }
        # No Entersekt data available
        return {
            "changed": False,
            "msg": "Entersekt SNMP data not found",
            "data": {"discovery": []},
        }

    # Normal check mode for single-service check
    # Get all values
    server_running = get_snmp_value(server_running_oid)
    emr_errors = get_snmp_value(emr_errors_oid)
    ecert_errors = get_snmp_value(ecert_errors_oid)
    soap_errors = get_snmp_value(soap_errors_oid)
    cert_days = get_snmp_value(cert_days_oid)

    # Determine which check to perform based on item or default to server status
    # Since Checkmk checks are separate plugins but we have one entry point,
    # we'll default to server status if no specific item provided
    item = params.get("item", "server_status")

    # Map to checkmk plugin names as implied by service names
    if item == "server_status" or item == "":
        # Server Status check
        if server_running == None:
            return {
                "changed": False,
                "msg": "Entersekt server status unknown (SNMP query failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        if server_running == "true":
            return {
                "changed": False,
                "msg": "Server is running",
                "data": {"state": "OK", "metrics": {}, "details": ""},
            }
        else:
            return {
                "changed": False,
                "msg": "Server is NOT running",
                "data": {"state": "CRIT", "metrics": {}, "details": ""},
            }

    elif item == "http_emr_errors":
        # EMR Errors check
        warn = params.get("warn", 100)
        crit = params.get("crit", 200)
        if emr_errors == None:
            return {
                "changed": False,
                "msg": "EMR errors unknown (SNMP query failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        if not str(emr_errors).isdigit():
            return {
                "changed": False,
                "msg": "EMR errors unknown (invalid value)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        errors = int(emr_errors)

        if errors >= crit:
            state = "CRIT"
        elif errors >= warn:
            state = "WARN"
        else:
            state = "OK"

        return {
            "changed": False,
            "msg": "Number of errors is %d" % errors,
            "data": {"state": state, "metrics": {"Errors": errors}, "details": ""},
        }

    elif item == "http_ecert_errors":
        # Ecert Errors check
        warn = params.get("warn", 100)
        crit = params.get("crit", 200)
        if ecert_errors == None:
            return {
                "changed": False,
                "msg": "Ecert errors unknown (SNMP query failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        if not str(ecert_errors).isdigit():
            return {
                "changed": False,
                "msg": "Ecert errors unknown (invalid value)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        errors = int(ecert_errors)

        if errors >= crit:
            state = "CRIT"
        elif errors >= warn:
            state = "WARN"
        else:
            state = "OK"

        return {
            "changed": False,
            "msg": "Number of errors is %d" % errors,
            "data": {"state": state, "metrics": {"Errors": errors}, "details": ""},
        }

    elif item == "soap_service_errors":
        # Soap Errors check (uses levels instead of warn/crit params)
        warn = params.get("warn", None)
        crit = params.get("crit", None)
        if soap_errors == None:
            return {
                "changed": False,
                "msg": "Soap errors unknown (SNMP query failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        if not str(soap_errors).isdigit():
            return {
                "changed": False,
                "msg": "Soap errors unknown (invalid value)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        errors = int(soap_errors)

        # Use default levels if not specified (same as Checkmk default: (None, None) means no levels)
        if warn == None and crit == None:
            # No levels specified -> always OK
            state = "OK"
        elif crit != None and errors >= crit:
            state = "CRIT"
        elif warn != None and errors >= warn:
            state = "WARN"
        else:
            state = "OK"

        return {
            "changed": False,
            "msg": "Number of errors is %d" % errors,
            "data": {"state": state, "metrics": {"Errors": errors}, "details": ""},
        }

    elif item == "certificate_expiration":
        # Certificate Expiration check
        warn = params.get("warn", 20)
        crit = params.get("crit", 10)
        if cert_days == None:
            return {
                "changed": False,
                "msg": "Certificate days unknown (SNMP query failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        if not str(cert_days).isdigit():
            return {
                "changed": False,
                "msg": "Certificate days unknown (invalid value)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        days = int(cert_days)

        # Lower levels (days less than threshold)
        if days < crit:
            state = "CRIT"
        elif days < warn:
            state = "WARN"
        else:
            state = "OK"

        return {
            "changed": False,
            "msg": "Number of days is %d" % days,
            "data": {"state": state, "metrics": {"Days": days}, "details": ""},
        }

    else:
        return {
            "changed": False,
            "msg": "Unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
