# Starlark check module for checkmk.mcafee_webgateway_info (read-only)
# The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway v12.2.2+

def main(ctx, params):
    # Discovery mode: always yield one service if the SNMP section exists
    if params.get("_discover"):
        # Probe both possible OIDs: McAfee (1230) and Skyhigh (59732)
        # Try McAfee first
        res_mc = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.1230.2.7.1.3", ".1.3.6.1.4.1.1230.2.7.1.9"
        ], mutates=False)

        # If empty or failed, try Skyhigh
        if not res_mc.stdout or "No Such Object" in res_mc.stdout or res_mc.rc != 0:
            res_sh = ctx.run([
                "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                ".1.3.6.1.4.1.59732.2.7.1.3", ".1.3.6.1.4.1.59732.2.7.1.9"
            ], mutates=False)
            if not res_sh.stdout or "No Such Object" in res_sh.stdout or res_sh.rc != 0:
                # No SNMP data found -> no services
                return {"changed": False, "msg": "discovered 0 items",
                        "data": {"discovery": []}}
            section = _parse_snmp_output(res_sh.stdout)
        else:
            section = _parse_snmp_output(res_mc.stdout)
    else:
        # Check mode: use stored section (simulated by parsing live SNMP here for simplicity)
        # In real Checkmk agent plugins, section data is passed to the check function.
        # For Starlark simulation, we re-run the probe using snmpwalk
        # (In production Checkmk, this is replaced with parsed_section access)
        res_mc = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.1230.2.7.1.3", ".1.3.6.1.4.1.1230.2.7.1.9"
        ], mutates=False)
        if not res_mc.stdout or "No Such Object" in res_mc.stdout or res_mc.rc != 0:
            res_sh = ctx.run([
                "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                ".1.3.6.1.4.1.59732.2.7.1.3", ".1.3.6.1.4.1.59732.2.7.1.9"
            ], mutates=False)
            if not res_sh.stdout or "No Such Object" in res_sh.stdout or res_sh.rc != 0:
                return {"changed": False, "msg": "no SNMP data available",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            section = _parse_snmp_output(res_sh.stdout)
        else:
            section = _parse_snmp_output(res_mc.stdout)

    # Discovery mode: yield exactly one service if section non-empty
    if params.get("_discover"):
        if section and len(section) > 0 and len(section[0]) >= 2:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # Check mode: extract version/revision from parsed SNMP section
    if not section or len(section) == 0 or len(section[0]) < 2:
        return {"changed": False, "msg": "no SNMP data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    version = section[0][0]
    revision = section[0][1]
    msg = "Product version: %s, Revision: %s" % (version, revision)
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": {}, "details": ""}}


def _parse_snmp_output(output):
    """
    Parse simple SNMP walk output into a list of [value1, value2] lists.
    Expected format per line: OID = STRING: "value"
    We expect two OIDs: .3 (version) and .9 (revision)
    """
    lines = output.splitlines()
    values = []
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        # Extract value after "STRING: "
        val = parts[1]
        if val.startswith("STRING: "):
            val = val[8:]
        # Strip quotes
        if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
            val = val[1:-1]
        values.append(val)
    if len(values) < 2:
        return []
    return [[values[0], values[1]]]
