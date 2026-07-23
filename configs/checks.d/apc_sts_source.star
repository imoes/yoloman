def main(ctx, params):
    if params.get("_discover"):
        # Detect device by checking the system OID suffix
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP check failed",
                    "data": {"discovery": []}}
        # Check for APC STS device OID .1.3.6.1.4.1.705.2.2
        if ".1.3.6.1.4.1.705.2.2" not in res.stdout:
            return {"changed": False, "msg": "not an APC STS device",
                    "data": {"discovery": []}}

        # Fetch the two source status OIDs
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), ".1.3.6.1.4.1.705.2"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}

        # Extract values for .3.5 (source1) and .4.5 (source2)
        source1 = ""
        source2 = ""
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts[0], parts[1]
            # Parse OID and value
            if oid_part.endswith(".3.5"):
                # Extract numeric value after colon (TYPE: value)
                val = value_part.split(": ", 1)
                if len(val) == 2:
                    source1 = val[1].strip()
            elif oid_part.endswith(".4.5"):
                val = value_part.split(": ", 1)
                if len(val) == 2:
                    source2 = val[1].strip()

        # Only discover if both values are present
        if source1 and source2:
            return {"changed": False, "msg": "discovered Source service",
                    "data": {"discovery": [{"item": "", "params": {"source1": source1, "source2": source2}, "metrics": []}]}}
        else:
            return {"changed": False, "msg": "APC STS source values not found",
                    "data": {"discovery": []}}

    # Check mode (non-discovery)
    source1_expected = params.get("source1", "")
    source2_expected = params.get("source2", "")

    # Fetch current source values
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), ".1.3.6.1.4.1.705.2"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "SNMP check failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    current_source1 = ""
    current_source2 = ""
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts[0], parts[1]
        if oid_part.endswith(".3.5"):
            val = value_part.split(": ", 1)
            if len(val) == 2:
                current_source1 = val[1].strip()
        elif oid_part.endswith(".4.5"):
            val = value_part.split(": ", 1)
            if len(val) == 2:
                current_source2 = val[1].strip()

    # If data is missing, report UNKNOWN
    if not current_source1 or not current_source2:
        return {"changed": False, "msg": "APC STS source values not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Map state strings
    states = {"1": "in use", "2": "not used"}

    # Check source1
    state = "OK"
    details = []
    info1 = "Source 1: " + states.get(current_source1, current_source1)
    if source1_expected and source1_expected != current_source1:
        state = "WARN"
        info1 += " (State has changed)"
    details.append(info1)

    # Check source2
    info2 = "Source 2: " + states.get(current_source2, current_source2)
    if source2_expected and source2_expected != current_source2:
        state = "WARN"
        info2 += " (State has changed)"
    details.append(info2)

    return {"changed": False, "msg": "; ".join(details),
            "data": {"state": state, "metrics": {}, "details": ""}}
