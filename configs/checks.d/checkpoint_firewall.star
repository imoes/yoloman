def main(ctx, params):
    # Discovery mode: yield one service for this host if the section is present
    if params.get("_discover"):
        # Check if the SNMP section 'checkpoint_firewall' is present by probing the OID
        # .1.3.6.1.4.1.2620.1.1.1 (firewall state OID)
        res = ctx.run([
            "snmpget",
            "-On",
            "-v2c",
            "-c", "public",
            ".1.3.6.1.4.1.2620.1.1.1"
        ], mutates=False)
        
        # If the command succeeded and returned a non-empty response (or rc == 0),
        # we assume the section is present. Checkmk's DETECT logic uses multiple
        # conditions, but we only need to probe one of them (the first OID in the tree).
        # In practice, the Checkmk agent would provide the section via the agent,
        # but for standalone Starlark we simulate detection via snmpget.
        if res.rc == 0 and res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": []
                        }
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []}
        }

    # Check mode (normal operation)
    # Simulate reading the checkpoint_firewall section from agent output.
    # In Checkmk, the agent provides the string table; here we mimic it.
    # We'll use snmpget for the required OIDs: .1.3.6.1.4.1.2620.1.1.1,2,3,8,9
    # to get [state, filter_name, filter_date, major, minor]
    oids = [
        ".1.3.6.1.4.1.2620.1.1.1",
        ".1.3.6.1.4.1.2620.1.1.2",
        ".1.3.6.1.4.1.2620.1.1.3",
        ".1.3.6.1.4.1.2620.1.1.8",
        ".1.3.6.1.4.1.2620.1.1.9"
    ]
    
    # Gather all OIDs in one go using snmpwalk or multiple snmpget
    # For simplicity and compatibility, use snmpwalk on the base OID
    res = ctx.run([
        "snmpwalk",
        "-On",
        "-v2c",
        "-c", "public",
        ".1.3.6.1.4.1.2620.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to gather SNMP data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse the snmpwalk output
    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract the last part of OID
        oid_suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
        # Map to the expected indices: 1,2,3,8,9 -> indices 0,1,2,3,4
        if oid_suffix == "1":
            data["state"] = value_part
        elif oid_suffix == "2":
            data["filter_name"] = value_part
        elif oid_suffix == "3":
            data["filter_date"] = value_part
        elif oid_suffix == "8":
            data["major"] = value_part
        elif oid_suffix == "9":
            data["minor"] = value_part
    
    # If any expected field is missing, report UNKNOWN
    required_fields = ["state", "filter_name", "filter_date", "major", "minor"]
    for field in required_fields:
        if field not in data:
            return {
                "changed": False,
                "msg": "missing required SNMP data field: " + field,
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": ""
                }
            }
    
    # Parse values: strip quotes and leading/trailing whitespace
    def strip_value(v):
        # Remove leading/trailing whitespace and quotes
        v = v.strip()
        if v.startswith('"') and v.endswith('"'):
            v = v[1:-1]
        return v.strip()
    
    state = strip_value(data["state"]).lower()
    filter_name = strip_value(data["filter_name"])
    filter_date = strip_value(data["filter_date"])
    major = strip_value(data["major"])
    minor = strip_value(data["minor"])
    
    if state == "installed":
        summary = "%s (v%s.%s), filter: %s (since %s)" % (state, major, minor, filter_name, filter_date)
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    
    # Any non-"installed" state is CRITICAL
    summary = "not installed, state: %s" % state
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "CRIT",
            "metrics": {},
            "details": ""
        }
    }
