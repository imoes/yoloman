def main(ctx, params):
    # This is an SNMP-based check. Read the same scalar OID the Checkmk
    # plugin reads: .1.3.6.1.4.1.12356.113.1.202.23 (facAuthFailures5Min)
    oid = "1.3.6.1.4.1.12356.113.1.202.23"
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe the scalar that the FortiAuthenticator SNMP section reads.
        # Detection (DETECT_FORTIAUTHENTICATOR) is not reproducible here:
        # it depends on the enterprise-OID of the device. We only emit a
        # service when the scalar OID is actually reachable and returns a
        # numeric value, which means the device answered.
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        raw = res.stdout.strip()
        if raw == "" or not raw.lstrip("-").isdigit():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        levels = params.get("auth_fails", (100, 200))
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"auth_fails": levels},
                     "metrics": ["fortiauthenticator_fails_5min"]},
                ]}}

    # CHECK MODE: read the single scalar value.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed: %s" % res.stderr,
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": ""}}
    raw = res.stdout.strip()
    if raw == "" or not raw.lstrip("-").isdigit():
        return {"changed": False, "msg": "no authentication failure value",
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": ""}}
    value = int(raw)

    levels = params.get("auth_fails", (100, 200))
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Authentication failures within the last 5 minutes: %d (warn/crit at %d/%d)" % (value, warn, crit),
        "data": {
            "state": state,
            "metrics": {"fortiauthenticator_fails_5min": value},
            "details": "",
        },
    }