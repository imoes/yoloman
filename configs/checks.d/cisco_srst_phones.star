def main(ctx, params):
    # Discovery mode: always yield one service for this check
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["registered_phones"]}]}
        }

    # Check mode: fetch the SNMP value for cisco_srst_phones
    # The OID is .1.3.6.1.4.1.9.9.441.1.3.2 (from SNMPTree base + oid)
    # We use ctx.run to execute snmpget; checkmk's runtime provides snmpwalk/snmpget
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", "1.3.6.1.4.1.9.9.441.1.3.2"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse output: expect something like "SNMPv2-SMI::enterprises.9.9.441.1.3.2.0 = INTEGER: 5"
    # We only need the integer value at the end
    line = res.stdout.strip()
    parts = line.split()
    if len(parts) < 4:
        return {
            "changed": False,
            "msg": "unexpected SNMP output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # The last token should be the integer value
    value_str = parts[-1]
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "SNMP value is not an integer: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    phones = int(value_str)
    return {
        "changed": False,
        "msg": "%d phones registered" % phones,
        "data": {
            "state": "OK",
            "metrics": {"registered_phones": phones},
            "details": ""
        }
    }
