def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Checkmk discovery yields a single service for this check
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: single-service check, item is always ""
    # Probe via SNMP: need to detect if host matches bintec OIDs first
    # We simulate detection by trying to fetch the relevant OIDs

    # OID 1.3.6.1.2.1.1.2.0 is sysObjectID.0 — try to get it first to detect bintec
    # We'll fetch both detection OIDs and data OIDs in one go using snmpget
    # But ctx.run only supports CLI tools; we assume the host has snmpget/snmpwalk

    # Attempt SNMPv2c query for required OIDs (since bintec uses standard SNMPv2)
    # Note: Checkmk agent-based plugins assume data is already collected by the agent;
    # However, this check uses SNMP. Since Starlark checks in Checkmk runtime can
    # access agent sections directly, we must simulate the agent section parsing.

    # In Checkmk's runtime, when a check runs, the section data is already available
    # via ctx.agent_section. But per the Starlark contract, we only have ctx.run and
    # file-based probes. Since the original check is SNMP-based and no agent section
    # is exposed here, the most realistic translation for a checkmk.check plugin is:
    #   - In checkmk agent-based infrastructure, this would read from agent output
    #   - But as a standalone check, we must use SNMP CLI tools.

    # Let's use snmpget to fetch the two OIDs: sw_version OID and serial OID
    # We'll try a single snmpget call for both OIDs on the localhost (default)
    # We assume default SNMP settings: public, v2c, localhost

    # Fetch both OIDs at once
    sw_oid = ".1.3.6.1.4.1.272.4.1.26.0"
    serial_oid = ".1.3.6.1.4.1.272.4.1.31.0"
    
    # Try snmpget for both OIDs
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-cpublic", "localhost",
        sw_oid, serial_oid
    ], mutates=False)
    
    # Parse output: each line looks like: OID = STRING: "value"
    sw_version = None
    serial = None
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        if oid_part.strip() == sw_oid:
            # Extract string value from "STRING: \"...\"" or similar
            # Common formats: STRING: "1.2.3", OCTET STRING: "abc", etc.
            val = val_part.strip()
            # Strip common prefixes: "STRING: ", "OCTET STRING: ", etc.
            for prefix in ("STRING: ", "OCTET STRING: "):
                if val.startswith(prefix):
                    val = val[len(prefix):]
            # Remove quotes if present
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            sw_version = val
        elif oid_part.strip() == serial_oid:
            val = val_part.strip()
            for prefix in ("STRING: ", "OCTET STRING: "):
                if val.startswith(prefix):
                    val = val[len(prefix):]
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            serial = val

    # Fallback: if snmpget failed, try alternative detection via sysObjectID
    # We won't do full detection logic here — if data is missing, report UNKNOWN

    # If we got neither value, return UNKNOWN
    if sw_version == None or serial == None:
        # Try once more with v1 or different community? Skip — just report UNKNOWN
        return {
            "changed": False,
            "msg": "No data retrieved",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Normal case: we have both
    summary = "Serial: %s, Software: %s" % (serial, sw_version)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }
