def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Walk all required SNMP trees for wagner_titanus_topsense
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.2.1.1",
            ".1.3.6.1.4.1.34187.21501.1.1",
            ".1.3.6.1.4.1.34187.21501.2.1",
            ".1.3.6.1.4.1.34187.74195.1.1",
            ".1.3.6.1.4.1.34187.74195.2.1"
        ], mutates=False)
        # Check if at least one device is detected by verifying OID presence
        lines = res.stdout.splitlines()
        has_device = False
        for line in lines:
            if line.startswith(".1.3.6.1.2.1.1.2.0 =") and (
                ".1.3.6.1.4.1.34187.21501" in line or ".1.3.6.1.4.1.34187.74195" in line
            ):
                has_device = True
                break
        if not has_device:
            return {"changed": False, "msg": "no wagner titanus topsense device detected",
                    "data": {"discovery": []}}
        # Two chamber deviation detectors (item "1" and "2")
        discovery_list = [
            {"item": "1", "params": {}, "metrics": ["chamber_deviation"]},
            {"item": "2", "params": {}, "metrics": ["chamber_deviation"]},
        ]
        return {"changed": False, "msg": "discovered 2 chamber deviation detectors",
                "data": {"discovery": discovery_list}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Get chamber deviation values from OID tree .1.3.6.1.4.1.34187.21501.2.1
    # For item "1": OID suffix .245950000
    # For item "2": OID suffix .246090000
    base_oid = ".1.3.6.1.4.1.34187.21501.2.1"
    if item == "1":
        oid = base_oid + ".245950000"
    elif item == "2":
        oid = base_oid + ".246090000"
    else:
        return {"changed": False, "msg": "Chamber Deviation Detector " + item + " not found in SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Failed to retrieve chamber deviation for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse "OID = STRING: value"
    line = res.stdout.strip()
    # Check for empty or malformed response
    if line == "" or "=" not in line:
        return {"changed": False, "msg": "Unexpected SNMP response format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_str = line.split(" = ")[1].strip()
    # Strip quotes if present
    if value_str.startswith('"') and value_str.endswith('"'):
        value_str = value_str[1:-1]
    if not value_str:
        return {"changed": False, "msg": "Empty chamber deviation value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    chamber_deviation = 0.0
    if value_str.replace(".", "").lstrip("-").isdigit() or value_str.replace(".", "").lstrip("-").replace("-", "").isdigit():
        chamber_deviation = float(value_str)
    else:
        # Handle non-numeric response gracefully
        return {"changed": False, "msg": "Chamber Deviation value is non-numeric: " + value_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {
        "changed": False,
        "msg": "%f%% Chamber Deviation" % chamber_deviation,
        "data": {
            "state": "OK",
            "metrics": {"chamber_deviation": chamber_deviation},
            "details": "",
        },
    }