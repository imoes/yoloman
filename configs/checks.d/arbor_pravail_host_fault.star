def main(ctx, params):
    if params.get("_discover"):
        # Single-service check: always discover exactly one Service with item ""
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: fetch host fault string via SNMP
    # Section base for arbor_pravail_host_fault is .1.3.6.1.4.1.9694.1.6.2
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.9694.1.6.2.1.0"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Expected format: .1.3.6.1.4.1.9694.1.6.2.1.0 = STRING: "<fault string>"
    output = res.stdout.strip()
    # Extract value after " = STRING: "
    pos = output.find(" = STRING: ")
    if pos == -1:
        return {
            "changed": False,
            "msg": "unexpected SNMP output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    fault_str = output[pos + len(" = STRING: "):].strip().strip('"')
    state = "OK" if fault_str == "No Fault" else "CRIT"
    return {
        "changed": False,
        "msg": fault_str,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
