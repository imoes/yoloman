def _snmp_get_str(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing first: the BDT tape library sysoid.
        detect_oid = ".1.3.6.1.2.1.1.2.0"
        detect_val = _snmp_get_str(ctx, params.get("community", "public"), params.get("host", "localhost"), detect_oid)
        if detect_val == None:
            return {"changed": False, "msg": "no SNMP agent reachable", "data": {"discovery": [], "host_labels": {}}}
        if ".1.3.6.1.4.1.20884.10893.2.101" not in detect_val:
            return {"changed": False, "msg": "BDT tape library not present", "data": {"discovery": [], "host_labels": {}}}

        base = ".1.3.6.1.2.1.1.2.0"
        name = _snmp_get_str(ctx, params.get("community", "public"), params.get("host", "localhost"), ".1.3.6.1.4.1.20884.10893.2.101.1.1")
        if name == None:
            return {"changed": False, "msg": "BDT tape library not present", "data": {"discovery": [], "host_labels": {}}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ],
            },
        }

    # Check mode: read the four OIDs from the BDT tape info subtree.
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oids = [
        ".1.3.6.1.4.1.20884.10893.2.101.1.1",
        ".1.3.6.1.4.1.20884.10893.2.101.1.2",
        ".1.3.6.1.4.1.20884.10893.2.101.1.3",
        ".1.3.6.1.4.1.20884.10893.2.101.1.4",
    ]
    fields = ["Name", "Description", "Vendor", "Agent Version"]
    values = []
    for oid in oids:
        v = _snmp_get_str(ctx, community, host, oid)
        if v == None:
            return {
                "changed": False,
                "msg": "BDT tape library data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Failed to read BDT tape info OIDs"},
            }
        values.append(v)

    summary_parts = []
    for name, value in zip(fields, values):
        summary_parts.append("%s: %s" % (name, value))

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {"state": "OK", "metrics": {}, "details": "\n".join(summary_parts)},
    }