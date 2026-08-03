def main(ctx, params):
    # Arbor Peakflow TMS / Arbor Pravail host-fault check.
    # Monitors a single scalar SNMP OID exposing the appliance's host-fault
    # status string. "No Fault" -> OK, anything else -> CRIT.

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")

    # Discovery path: probe the appliance and report a single service
    # ("Host Fault") when the host-fault OID is reachable.
    if params.get("_discover"):
        # Peakflow TMS host-fault OID base: .1.3.6.1.4.1.9694.1.5.2
        # Pravail host-fault OID base:     .1.3.6.1.4.1.9694.1.6.2
        oid_pf = "1.3.6.1.4.1.9694.1.5.2.1.0"
        oid_pr = "1.3.6.1.4.1.9694.1.6.2.1.0"

        found = False
        # Try Peakflow TMS first, then Pravail.
        for oid in [oid_pf, oid_pr]:
            res = ctx.run(
                ["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid],
                mutates=False,
            )
            if res.rc == 0 and res.stdout.strip() != "":
                found = True
                break
        if not found:
            return {
                "changed": False,
                "msg": "no Arbor host fault reachable",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]
            },
        }

    # Check path: read the host-fault status string.
    oid_pf = "1.3.6.1.4.1.9694.1.5.2.1.0"
    oid_pr = "1.3.6.1.4.1.9694.1.6.2.1.0"

    status = None
    for oid in [oid_pf, oid_pr]:
        res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip() != "":
            status = res.stdout.strip()
            break

    if status == None:
        return {
            "changed": False,
            "msg": "host fault OID unreachable",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    state = "OK" if status == "No Fault" else "CRIT"
    return {
        "changed": False,
        "msg": status,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }