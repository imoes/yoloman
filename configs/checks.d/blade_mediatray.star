def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.2.3.51.2.2.5.2.74"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 services",
                    "data": {"discovery": []}}
        # Check if the OID returns "1" (present) - only one service expected
        lines = res.stdout.strip().split("\n")
        for line in lines:
            if line.strip() == "" or not ":" in line:
                continue
            value = line.strip().split(":")[-1].strip()
            if value == "1":
                return {"changed": False, "msg": "discovered 1 service",
                        "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "discovered 0 services",
                "data": {"discovery": []}}

    # Check mode (no item, single-service check)
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.2.3.51.2.2.5.2.74", ".1.3.6.1.4.1.2.3.51.2.2.5.2.75"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no information about media tray in SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse SNMP output - extract values from snmpget response
    lines = res.stdout.strip().split("\n")
    present = None
    communicating = None
    for line in lines:
        if line.strip() == "" or not ":" in line:
            continue
        value = line.strip().split(":")[-1].strip()
        if ".74" in line and present == None:
            present = value
        elif ".75" in line and communicating == None:
            communicating = value

    if present == None or communicating == None:
        return {"changed": False, "msg": "no information about media tray in SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if present != "1":
        return {"changed": False, "msg": "media tray not present",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    if communicating != "1":
        return {"changed": False, "msg": "media tray not communicating",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "media tray present and communicating",
            "data": {"state": "OK", "metrics": {}, "details": ""}}
