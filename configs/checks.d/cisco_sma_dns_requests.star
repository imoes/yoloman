def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: the Cisco SMA SNMP device via its
        # detection OIDs. If snmpget/snmpwalk is missing or the device
        # does not respond, this check does not apply.
        res = ctx.run(
            ["snmpget", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqv",
             "-t", "3",
             params.get("host", "localhost"),
             ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if res.rc != 0:
            # 127 = binary missing; any non-zero = device/feature absent
            return {"changed": False, "msg": "no Cisco SMA device found",
                    "data": {"discovery": []}}

        # Walk the two columns of the DNS requests table.
        res = ctx.run(
            ["snmpwalk", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqn",
             "-t", "3",
             params.get("host", "localhost"),
             ".1.3.6.1.4.1.15497.1.1.1.15.0"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no DNS request data available",
                    "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        if not lines:
            return {"changed": False, "msg": "no DNS request data available",
                    "data": {"discovery": []}}

        # Single-service check: one Service with item "".
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "",
                 "params": {
                     "pending_dns_levels": params.get("pending_dns_levels", ("no_levels", None)),
                     "outstanding_dns_levels": params.get("outstanding_dns_levels", ("no_levels", None)),
                 },
                 "metrics": ["pending_dns_requests", "outstanding_dns_requests"]},
            ]},
        }

    # CHECK MODE for the single service (item "").
    base = ".1.3.6.1.4.1.15497.1.1.1"
    oid_pending = base + ".15.0"
    oid_outstanding = base + ".16.0"

    res_p = ctx.run(["snmpget", "-v2c",
                     "-c", params.get("community", "public"),
                     "-Oqv", "-t", "3",
                     params.get("host", "localhost"),
                     oid_pending], mutates=False)
    res_o = ctx.run(["snmpget", "-v2c",
                     "-c", params.get("community", "public"),
                     "-Oqv", "-t", "3",
                     params.get("host", "localhost"),
                     oid_outstanding], mutates=False)

    if res_p.rc != 0 or res_o.rc != 0:
        return {"changed": False,
                "msg": "Cisco SMA DNS request data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    pending_raw = res_p.stdout.strip().strip('"')
    outstanding_raw = res_o.stdout.strip().strip('"')

    pending = int(pending_raw) if pending_raw.isdigit() else 0
    outstanding = int(outstanding_raw) if outstanding_raw.isdigit() else 0

    def grade_upper(value, levels):
        # levels is ("no_levels", None) or (warn, crit)
        if levels == None:
            return "OK"
        if type(levels) == "tuple" and len(levels) == 2 and levels[0] == "no_levels":
            return "OK"
        # levels interpreted as (warn, crit)
        if type(levels) == "list" or type(levels) == "tuple":
            warn = None
            crit = None
            if len(levels) >= 1 and levels[0] != None:
                warn = levels[0]
            if len(levels) >= 2 and levels[1] != None:
                crit = levels[1]
            if crit != None and value >= crit:
                return "CRIT"
            if warn != None and value >= warn:
                return "WARN"
            return "OK"
        return "OK"

    pend_levels = params.get("pending_dns_levels", ("no_levels", None))
    out_levels = params.get("outstanding_dns_levels", ("no_levels", None))

    pend_state = grade_upper(pending, pend_levels)
    out_state = grade_upper(outstanding, out_levels)

    if pend_state == "CRIT" or out_state == "CRIT":
        state = "CRIT"
    elif pend_state == "WARN" or out_state == "WARN":
        state = "WARN"
    else:
        state = "OK"

    msg = "Pending: %d, Outstanding: %d" % (pending, outstanding)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"pending_dns_requests": pending, "outstanding_dns_requests": outstanding},
            "details": "",
        },
    }