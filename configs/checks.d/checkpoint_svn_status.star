def main(ctx, params):
    discover = params.get("_discover", False)
    community = params.get("community", "public")
    host = params.get("host", ctx.facts().get("hostname", "localhost"))

    # Probe for the real thing: a Check Point product running on the host.
    # Detection mirrors cmk.plugins.checkpoint.lib.DETECT.
    sys_desc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    sys_oid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )

    if sys_desc.rc != 0 or sys_oid.rc != 0:
        # Not reachable via SNMP -> not a Check Point device for us.
        if discover:
            return {"changed": False, "msg": "not SNMP-reachable", "data": {"discovery": []}}
        return {"changed": False, "msg": "SNMP not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_oid_val = sys_oid.stdout.strip()
    sys_desc_val = sys_desc.stdout.strip()

    # all_of(
    #   any_of(
    #     startswith(sys_oid, ".1.3.6.1.4.1.2620"),
    #     matches(sys_desc, "[^ ]+ [^ ]+ [^ ]*cp( .*)?"),
    #     startswith(sys_desc, "IPSO "),
    #     matches(sys_desc, "Linux.*cpx.*"),
    #   ),
    #   any_of(
    #     startswith(".1.3.6.1.4.1.2620.1.1.21.0", "firewall"),
    #     matches(".1.3.6.1.4.1.2620.1.6.5.1.0", "Gaia"),
    #   ),
    # )
    oid_ok = sys_oid_val.startswith(".1.3.6.1.4.1.2620")
    desc_ok = (sys_desc_val.startswith("IPSO ") or
               sys_desc_val.find("cpx") != -1 or
               _matches_cp(sys_desc_val))

    fw = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2620.1.1.21.0"],
        mutates=False,
    )
    gaia = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2620.1.6.5.1.0"],
        mutates=False,
    )

    fw_val = fw.stdout.strip() if fw.rc == 0 else ""
    gaia_val = gaia.stdout.strip() if gaia.rc == 0 else ""
    fw_ok = fw_val.startswith("firewall")
    gaia_ok = gaia_val.find("Gaia") != -1

    detected = (oid_ok or desc_ok) and (fw_ok or gaia_ok)

    if not detected:
        if discover:
            return {"changed": False, "msg": "not a Check Point device", "data": {"discovery": []}}
        return {"changed": False, "msg": "host is not a Check Point device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch the SVN status table: .1.3.6.1.4.1.2620.1.6 with OIDs 2,3,101,103.
    tree = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.2620.1.6.2",
         ".1.3.6.1.4.1.2620.1.6.3",
         ".1.3.6.1.4.1.2620.1.6.101",
         ".1.3.6.1.4.1.2620.1.6.103"],
        mutates=False,
    )

    out = tree.stdout.strip() if tree.rc == 0 else ""
    if not out:
        if discover:
            return {"changed": False, "msg": "no SVN status data", "data": {"discovery": []}}
        return {"changed": False, "msg": "no SVN status data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # snmpget -Oqv with multiple OIDs returns one value per line, in order.
    vals = out.splitlines()
    if len(vals) < 4:
        if discover:
            return {"changed": False, "msg": "insufficient SVN status data", "data": {"discovery": []}}
        return {"changed": False, "msg": "insufficient SVN status data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    major = vals[0]
    minor = vals[1]
    code = vals[2]
    description = vals[3]

    # Discovery: single-service check, one item with no per-item metrics.
    if discover:
        return {"changed": False,
                "msg": "discovered 1 SVN status item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    # Check mode for the single service (item is "").
    ver = "v%s.%s" % (major, minor)

    code_stripped = code.strip()
    if code_stripped != "" and int(code_stripped) != 0:
        summary = description.strip() if description.strip() else "Error code %s (%s)" % (code_stripped, ver)
        return {"changed": False, "msg": summary,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "OK (%s)" % ver,
            "data": {"state": "OK", "metrics": {}, "details": ""}}


def _matches_cp(s):
    # matches ".1.3.6.1.2.1.1.1.0", "[^ ]+ [^ ]+ [^ ]*cp( .*)?"
    # i.e. sysDescr has at least 3 tokens where the third-ish contains "cp"
    parts = s.split(" ")
    if len(parts) < 3:
        return False
    for p in parts:
        if p.find("cp") != -1:
            return True
    return False