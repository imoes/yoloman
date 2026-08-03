def main(ctx, params):
    # This check monitors Brocade system memory via SNMP.
    # The data comes from SNMP OIDs .1.3.6.1.4.1.1588.2.1.1.1.26 (cpu_util at .1, mem_used_percent at .6)
    # We use net-snmp to poll the device directly.

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", None)

    base_oid = ".1.3.6.1.4.1.1588.2.1.1.1.26"

    if params.get("_discover"):
        # Discovery mode: probe for the Brocade system via the standard OID
        # and check if this is a Brocade device by reading sysObjectID.
        sysoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )

        # If the device is unreachable or not a Brocade, no services are discovered
        if sysoid_res.rc != 0:
            return {"changed": False, "msg": "no Brocade device reachable", "data": {"discovery": []}}

        sysoid = sysoid_res.stdout.strip()

        # Only discover on Brocade devices (Brocade FID/EID: .1.3.6.1.4.1.1588.2.1.1, or older .1.3.6.1.4.1.1916.2.306)
        is_brocade = (
            sysoid.startswith(".1.3.6.1.4.1.1588.2.1.1") or
            sysoid == ".1.3.6.1.4.1.1916.2.306"
        )

        if not is_brocade:
            return {"changed": False, "msg": "not a Brocade device", "data": {"discovery": []}}

        # Probe the actual metric OIDs to confirm data is available
        mem_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".6"],
            mutates=False,
        )

        if mem_res.rc != 0:
            return {"changed": False, "msg": "no Brocade memory data available", "data": {"discovery": []}}

        # Single-service check: returns one item with ""
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": None},
                        "metrics": ["mem_used_percent"],
                    }
                ]
            },
        }

    # Check mode: read the memory utilization for this single-service check
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".6"],
        mutates=False,
    )

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "no Brocade device reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    stdout = res.stdout.strip()
    if stdout == "":
        return {
            "changed": False,
            "msg": "no memory data returned",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mem_used_percent = 0
    if stdout.isdigit():
        mem_used_percent = int(stdout)
    else:
        return {
            "changed": False,
            "msg": "could not parse memory value: %s" % stdout,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    if levels != None:
        warn_level = levels[0] if type(levels) == "list" and len(levels) >= 1 else None
        crit_level = levels[1] if type(levels) == "list" and len(levels) >= 2 else None
        if crit_level != None and mem_used_percent >= crit_level:
            state = "CRIT"
        elif warn_level != None and mem_used_percent >= warn_level:
            state = "WARN"

    return {
        "changed": False,
        "msg": "Memory: %d%% used" % mem_used_percent,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": mem_used_percent},
            "details": "",
        },
    }