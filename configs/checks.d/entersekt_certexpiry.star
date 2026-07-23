def main(ctx, params):
    # SNMP base OID for Entersekt section
    base_oid = ".1.3.6.1.4.1.38235.2"

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid + ".3"
        ], mutates=False)

        # Parse output: look for any results in the Entersekt subtree
        found = False
        for line in res.stdout.splitlines():
            if line.strip() and base_oid in line:
                found = True
                break

        if found:
            return {
                "changed": False,
                "msg": "discovered 1 services",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 services",
                "data": {"discovery": []}
            }

    # Check mode - get required OID values via snmpget
    oid_status = base_oid + ".3.1.0"  # Server running status
    oid_emrerrors = base_oid + ".3.4.0"  # HTTP EMR errors
    oid_ecerterrors = base_oid + ".3.8.0"  # http Ecert errors
    oid_soaperrors = base_oid + ".3.9.0"  # Soap service errors
    oid_days = base_oid + ".17.1.0"  # Days until cert expiry

    # Fetch all needed OIDs
    oids_to_fetch = [oid_status, oid_emrerrors, oid_ecerterrors, oid_soaperrors, oid_days]
    values = {}

    for oid in oids_to_fetch:
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), oid
        ], mutates=False)

        if res.rc != 0 or not res.stdout.strip():
            values[oid] = None
            continue

        # Parse snmpget output: "OID = Type: value"
        line = res.stdout.strip()
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            values[oid] = None
            continue

        value_part = parts[1].strip()
        if value_part.startswith("INTEGER:"):
            values[oid] = int(value_part.split(":", 1)[1].strip())
        elif value_part.startswith("STRING:"):
            val = value_part.split(":", 1)[1].strip().strip('"')
            if val == "true":
                values[oid] = "true"
            elif val == "false":
                values[oid] = "false"
            else:
                values[oid] = val
        elif value_part.startswith("GAUGE:"):
            values[oid] = int(value_part.split(":", 1)[1].strip())
        elif value_part.startswith("Counter:"):
            values[oid] = int(value_part.split(":", 1)[1].strip())
        else:
            values[oid] = None

    # Check server status (oid_status)
    status = values.get(oid_status)
    if status == "true":
        state = "OK"
        summary = "Server is running"
    elif status == "false":
        state = "CRIT"
        summary = "Server is NOT running"
    else:
        state = "UNKNOWN"
        summary = "Server status unknown"

    # Check certificate expiration (oid_days)
    days = values.get(oid_days)
    if days == None:
        return {
            "changed": False,
            "msg": summary + " - Certificate days data unavailable",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Failed to retrieve certificate expiry days",
            },
        }

    warn = params.get("levels", (20, 10))[0] if params.get("levels") else 20
    crit = params.get("levels", (20, 10))[1] if params.get("levels") else 10

    # Certificate expiration uses lower thresholds
    if days < crit:
        state = "CRIT"
        summary = "Number of days until expiration is " + str(days) + " which is less than " + str(crit)
    elif days < warn:
        state = "WARN"
        summary = "Number of days until expiration is " + str(days) + " which is less than " + str(warn)
    else:
        state = "OK"
        summary = "Number of days is " + str(days)

    # Build metrics dict
    metrics = {"Days": days}
    if values.get(oid_emrerrors) != None:
        metrics["Errors"] = values[oid_emrerrors]
    if values.get(oid_ecerterrors) != None:
        metrics["Errors"] = values[oid_ecerterrors]  # Ecert errors overwrite Errors if present
    if values.get(oid_soaperrors) != None:
        metrics["Errors"] = values[oid_soaperrors]

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
