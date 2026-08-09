def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: a BVIP device responds on SNMP.
        detect_oids = [
            ".1.3.6.1.2.1.1.1.0",
        ]
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Use the sysDescr OID (1.3.6.1.2.1.1.1.0) to test for BVIP markers.
        sysoid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysoid.rc != 0:
            return {"changed": False, "msg": "no SNMP response from host",
                    "data": {"discovery": []}}
        desc = sysoid.stdout.strip()
        bvim_markers = ["flexidome", "vip-x", "dinion", "autodome"]
        is_bvip = False
        for marker in bvim_markers:
            if desc.find(marker) != -1:
                is_bvip = True
                break
        if not is_bvip:
            return {"changed": False, "msg": "host is not a BVIP device",
                    "data": {"discovery": []}}
        # BVIP device confirmed; fetch the System Info table (unit name & id).
        info = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.3967.1.1.1.1", ".1.3.6.1.4.1.3967.1.1.1.2"],
            mutates=False,
        )
        if info.rc != 0:
            return {"changed": False, "msg": "failed to fetch bvip_info OIDs",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                        "service_labels": {"bvip/device": "System Info"},
                    }
                ]
            },
        }

    # Check mode: fetch the two scalar OIDs.
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.3967.1.1.1.1", ".1.3.6.1.4.1.3967.1.1.1.2"],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "snmpget command not found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "SNMP query failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "incomplete bvip_info response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    unit_name = lines[0].strip()
    unit_id = lines[1].strip()
    if unit_name == unit_id:
        summary = "Unit Name/ID: " + unit_name
    else:
        summary = "Unit Name: %s, Unit ID: %s" % (unit_name, unit_id)
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {}, "details": summary},
    }