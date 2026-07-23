def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": [
                        "Success", "Referral", "NXRSet", "NXDomain", "Recursion", "Failure"
                    ]}
                ]
            }
        }
    
    # Check mode: get DNS query counters via SNMP
    # Bluecat DNS queries SNMP OIDs: .1.3.6.1.4.1.13315.3.1.2.2.2.1.{1-6}
    oid_base = ".1.3.6.1.4.1.13315.3.1.2.2.2.1"
    oids = ["1", "2", "3", "4", "5", "6"]
    value_names = ["Success", "Referral", "NXRSet", "NXDomain", "Recursion", "Failure"]
    
    # Build snmpget command for each OID
    res = ctx.run([
        "snmpget",
        "-On",
        "-v2c",
        "-cpublic",
        "localhost",
        oid_base + ".1",
        oid_base + ".2",
        oid_base + ".3",
        oid_base + ".4",
        oid_base + ".5",
        oid_base + ".6"
    ], mutates=False)
    
    # Parse output: extract integer values from lines like:
    # .1.3.6.1.4.1.13315.3.1.2.2.2.1.1.0 = Counter32: 12345
    lines = res.stdout.splitlines()
    if len(lines) < 6:
        fail("failed to retrieve DNS query counters")
    
    values = []
    for line in lines:
        # Extract value after last colon
        idx = line.rfind(":")
        if idx == -1:
            fail("failed to parse SNMP output")
        val_str = line[idx+1:].strip()
        # Convert to integer
        val = int(val_str)
        values.append(val)
    
    # Build metrics dict with raw values as rates (approximation for Starlark)
    # In Checkmk, get_rate uses value_store to compute rates; here we approximate
    # by using raw counter values since Starlark lacks persistent state
    metrics = {}
    for i, name in enumerate(value_names):
        metrics[name] = values[i] if i < len(values) else 0
    
    # State determination: always OK for this check
    # Checkmk's check_levels with no levels specified yields OK
    return {
        "changed": False,
        "msg": "DNS queries collected",
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": ""
        }
    }
