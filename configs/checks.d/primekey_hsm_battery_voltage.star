def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.22408.1.1.2.2.4.104.115.109"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        lines = res.stdout.splitlines()
        v1 = ""
        s1 = ""
        v2 = ""
        s2 = ""
        for line in lines:
            stripped = line.strip()
            if ".52.1" in stripped:
                parts = stripped.split(" = ", 1)
                if len(parts) == 2:
                    v1 = parts[1]
            elif ".53.1" in stripped:
                parts = stripped.split(" = ", 1)
                if len(parts) == 2:
                    s1 = parts[1]
            elif ".55.1" in stripped:
                parts = stripped.split(" = ", 1)
                if len(parts) == 2:
                    v2 = parts[1]
            elif ".56.1" in stripped:
                parts = stripped.split(" = ", 1)
                if len(parts) == 2:
                    s2 = parts[1]

        discovery = []
        # Process battery 1
        has_data_1 = (v1 != "") or (s1 != "")
        if has_data_1:
            voltage = None
            if "absence" in v1:
                voltage = "absence"
            elif v1 != "" and v1.endswith(" V"):
                voltage_str = v1[:-2]
                if voltage_str.replace(".", "", 1).isdigit() or (voltage_str.startswith("-") and voltage_str[1:].replace(".", "", 1).isdigit()):
                    voltage = float(voltage_str)
            state_fail = (s1 == "1")
            discovery.append({"item": "1", "params": {}, "metrics": ["voltage"]})

        # Process battery 2
        has_data_2 = (v2 != "") or (s2 != "")
        if has_data_2:
            voltage = None
            if "absence" in v2:
                voltage = "absence"
            elif v2 != "" and v2.endswith(" V"):
                voltage_str = v2[:-2]
                if voltage_str.replace(".", "", 1).isdigit() or (voltage_str.startswith("-") and voltage_str[1:].replace(".", "", 1).isdigit()):
                    voltage = float(voltage_str)
            state_fail = (s2 == "1")
            discovery.append({"item": "2", "params": {}, "metrics": ["voltage"]})

        return {"changed": False, "msg": "discovered %d batteries" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item != "1" and item != "2":
        return {"changed": False, "msg": "unknown battery item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    oid_base = ".1.3.6.1.4.1.22408.1.1.2.2.4.104.115.109"
    if item == "1":
        oid_voltage = oid_base + ".52.1"
        oid_status = oid_base + ".53.1"
    else:
        oid_voltage = oid_base + ".55.1"
        oid_status = oid_base + ".56.1"

    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        oid_voltage, oid_status
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "unexpected SNMP response length",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    v_line = lines[0].strip()
    s_line = lines[1].strip()

    voltage_str = ""
    status_str = ""
    if " = " in v_line:
        voltage_str = v_line.rsplit(" = ", 1)[1]
    if " = " in s_line:
        status_str = s_line.rsplit(" = ", 1)[1]

    voltage = None
    if "absence" in voltage_str:
        voltage = "absence"
    elif voltage_str != "" and voltage_str.endswith(" V"):
        voltage_str_clean = voltage_str[:-2]
        if voltage_str_clean.replace(".", "", 1).isdigit() or (voltage_str_clean.startswith("-") and voltage_str_clean[1:].replace(".", "", 1).isdigit()):
            voltage = float(voltage_str_clean)

    state_fail = False
    if status_str == "1":
        state_fail = True

    state = "OK"
    if state_fail:
        state = "CRIT"
    elif voltage == "absence":
        state = "OK"
    else:
        state = "OK"

    if voltage == "absence":
        msg = "PrimeKey HSM battery %s status absence" % item
    elif state_fail:
        msg = "PrimeKey HSM battery %s status not OK" % item
    else:
        msg = "PrimeKey HSM battery %s status OK" % item

    levels = params.get("levels")
    levels_lower = params.get("levels_lower")
    if voltage != None and voltage != "absence":
        if levels != None:
            warn, crit = levels
            if voltage >= crit:
                state = "CRIT"
            elif voltage >= warn:
                state = "WARN"
        if levels_lower != None and state == "OK":
            warn_low, crit_low = levels_lower
            if voltage <= crit_low:
                state = "CRIT"
            elif voltage <= warn_low:
                state = "WARN"

    metrics = {}
    if voltage != None and voltage != "absence":
        metrics["voltage"] = voltage

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}