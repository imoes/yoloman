def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.1.1.0"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        # Detect device by sysObjectID
        oid = ".1.3.6.1.2.1.1.2.0"
        # Extract sysObjectID value from walk output
        sys_objectid = ""
        for line in res.stdout.splitlines():
            if line.strip().startswith(oid + " = "):
                val = line.strip()[len(oid + " = "):].strip()
                if val.startswith(" enterprises:"):
                    val = ".1.3.6.1.4" + val[len(" enterprises:"):]
                elif val.startswith(" iso:"):
                    val = ".1" + val[len(" iso:"):]
                sys_objectid = val
                break
        # Check for supported OIDs
        if sys_objectid != ".1.3.6.1.4.1.34187.21501" and sys_objectid != ".1.3.6.1.4.1.34187.74195":
            return {"changed": False, "msg": "discovered 0 items (not a Wagner Titanus TOPsense device)",
                    "data": {"discovery": []}}

        # Perform full walk for data collection
        sections = {}
        section_trees = [
            (".1.3.6.1.2.1.1", [1, 3, 4, 5, 6]),
            (".1.3.6.1.4.1.34187.21501.1.1", [1, 2, 3, 1000, 1001, 1002, 1003, 1004, 1005, 1006]),
            (".1.3.6.1.4.1.34187.21501.2.1", [
                "245810000", "245820000", "245950000", "246090000", "245960000",
                "246100000", "245970000", "246110000", "24584008"
            ]),
            (".1.3.6.1.4.1.34187.74195.1.1", [1, 2, 3, 1000, 1001, 1002, 1003, 1004, 1005, 1006]),
            (".1.3.6.1.4.1.34187.74195.2.1", [
                "245790000", "245800000", "245940000", "246060000", "245950000",
                "246070000", "245960000", "246080000"
            ]),
        ]
        
        for base, oids in section_trees:
            oid_str = base + "." + ".".join([str(o) for o in oids])
            res_walk = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), oid_str
            ], mutates=False)
            if res_walk.rc == 0:
                sections[oid_str] = res_walk.stdout

        # Check for device-specific sections
        top1_section_exists = False
        top2_section_exists = False
        for oid_str in sections:
            if ".1.3.6.1.4.1.34187.21501." in oid_str:
                top1_section_exists = True
            if ".1.3.6.1.4.1.34187.74195." in oid_str:
                top2_section_exists = True

        # Single service check - always discover one service
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    # Check mode - item is "" for single-service check
    item = params.get("item", "")

    # Gather all required SNMP data
    snmp_comm = params.get("community", "public")
    snmp_host = params.get("host", "localhost")

    # Gather sysDescr, sysUpTime, sysContact, sysName, sysLocation
    base_mib_res = ctx.run([
        "snmpwalk", "-v2c", "-c", snmp_comm, "-On", snmp_host,
        ".1.3.6.1.2.1.1.1.0", ".1.3.6.1.2.1.1.3.0", ".1.3.6.1.2.1.1.4.0",
        ".1.3.6.1.2.1.1.5.0", ".1.3.6.1.2.1.1.6.0"
    ], mutates=False)
    if base_mib_res.rc != 0:
        return {"changed": False, "msg": "SNMP error for base MIB",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    base_data = {}
    for line in base_mib_res.stdout.splitlines():
        if " = " in line:
            oid_part = line.split(" = ")[0].strip()
            value_part = line.split(" = ")[1].strip()
            if oid_part == ".1.3.6.1.2.1.1.1.0":
                base_data["sysDescr"] = value_part
            elif oid_part == ".1.3.6.1.2.1.1.3.0":
                # Convert timeticks to seconds (value typically like "1234567")
                # Extract number from timeticks format like "1234567"
                if value_part.isdigit():
                    base_data["sysUpTime"] = int(value_part) // 100
                else:
                    base_data["sysUpTime"] = 0
            elif oid_part == ".1.3.6.1.2.1.1.4.0":
                contact_val = value_part.strip('"')
                base_data["sysContact"] = contact_val
            elif oid_part == ".1.3.6.1.2.1.1.5.0":
                name_val = value_part.strip('"')
                base_data["sysName"] = name_val
            elif oid_part == ".1.3.6.1.2.1.1.6.0":
                loc_val = value_part.strip('"')
                base_data["sysLocation"] = loc_val

    # Gather model info section (both models)
    model1_res = ctx.run([
        "snmpwalk", "-v2c", "-c", snmp_comm, "-On", snmp_host,
        ".1.3.6.1.4.1.34187.21501.1.1.1.0",
        ".1.3.6.1.4.1.34187.21501.1.1.2.0",
        ".1.3.6.1.4.1.34187.21501.1.1.3.0",
        ".1.3.6.1.4.1.34187.21501.1.1.1000.0",
        ".1.3.6.1.4.1.34187.21501.1.1.1001.0",
        ".1.3.6.1.4.1.34187.21501.1.1.1002.0",
        ".1.3.6.1.4.1.34187.21501.1.1.1003.0",
        ".1.3.6.1.4.1.34187.21501.1.1.1004.0",
        ".1.3.6.1.4.1.34187.21501.1.1.1005.0",
        ".1.3.6.1.4.1.34187.21501.1.1.1006.0"
    ], mutates=False)
    model1_data = {}
    if model1_res.rc == 0:
        for line in model1_res.stdout.splitlines():
            if " = " in line:
                oid_part = line.split(" = ")[0].strip()
                value_part = line.split(" = ")[1].strip()
                if oid_part.endswith(".1.1.1.0"):
                    model1_data["1"] = value_part
                elif oid_part.endswith(".1.1.2.0"):
                    model1_data["2"] = value_part
                elif oid_part.endswith(".1.1.3.0"):
                    model1_data["3"] = value_part
                elif oid_part.endswith(".1.1.1000.0"):
                    model1_data["1000"] = value_part
                elif oid_part.endswith(".1.1.1001.0"):
                    model1_data["1001"] = value_part
                elif oid_part.endswith(".1.1.1002.0"):
                    model1_data["1002"] = value_part
                elif oid_part.endswith(".1.1.1003.0"):
                    model1_data["1003"] = value_part
                elif oid_part.endswith(".1.1.1004.0"):
                    model1_data["1004"] = value_part
                elif oid_part.endswith(".1.1.1005.0"):
                    model1_data["1005"] = value_part
                elif oid_part.endswith(".1.1.1006.0"):
                    model1_data["1006"] = value_part

    model2_res = ctx.run([
        "snmpwalk", "-v2c", "-c", snmp_comm, "-On", snmp_host,
        ".1.3.6.1.4.1.34187.74195.1.1.1.0",
        ".1.3.6.1.4.1.34187.74195.1.1.2.0",
        ".1.3.6.1.4.1.34187.74195.1.1.3.0",
        ".1.3.6.1.4.1.34187.74195.1.1.1000.0",
        ".1.3.6.1.4.1.34187.74195.1.1.1001.0",
        ".1.3.6.1.4.1.34187.74195.1.1.1002.0",
        ".1.3.6.1.4.1.34187.74195.1.1.1003.0",
        ".1.3.6.1.4.1.34187.74195.1.1.1004.0",
        ".1.3.6.1.4.1.34187.74195.1.1.1005.0",
        ".1.3.6.1.4.1.34187.74195.1.1.1006.0"
    ], mutates=False)
    model2_data = {}
    if model2_res.rc == 0:
        for line in model2_res.stdout.splitlines():
            if " = " in line:
                oid_part = line.split(" = ")[0].strip()
                value_part = line.split(" = ")[1].strip()
                if oid_part.endswith(".1.1.1.0"):
                    model2_data["1"] = value_part
                elif oid_part.endswith(".1.1.2.0"):
                    model2_data["2"] = value_part
                elif oid_part.endswith(".1.1.3.0"):
                    model2_data["3"] = value_part
                elif oid_part.endswith(".1.1.1000.0"):
                    model2_data["1000"] = value_part
                elif oid_part.endswith(".1.1.1001.0"):
                    model2_data["1001"] = value_part
                elif oid_part.endswith(".1.1.1002.0"):
                    model2_data["1002"] = value_part
                elif oid_part.endswith(".1.1.1003.0"):
                    model2_data["1003"] = value_part
                elif oid_part.endswith(".1.1.1004.0"):
                    model2_data["1004"] = value_part
                elif oid_part.endswith(".1.1.1005.0"):
                    model2_data["1005"] = value_part
                elif oid_part.endswith(".1.1.1006.0"):
                    model2_data["1006"] = value_part

    # Prefer model 1 if available, otherwise model 2
    model_data = model1_data if model1_data else model2_data

    # Gather LSN bus status
    lsn_res = ctx.run([
        "snmpwalk", "-v2c", "-c", snmp_comm, "-On", snmp_host,
        ".1.3.6.1.4.1.34187.21501.2.1.24584008.0"
    ], mutates=False)
    lsn_status = ""
    if lsn_res.rc == 0:
        for line in lsn_res.stdout.splitlines():
            if " = " in line:
                value_part = line.split(" = ")[1].strip()
                lsn_status = value_part
                break
    # Map LSN status
    if lsn_status == "0":
        lsn_status = "offline"
    elif lsn_status == "1":
        lsn_status = "online"
    else:
        lsn_status = "unknown"

    # Build message
    message = "System: " + base_data.get("sysDescr", "")
    message += ", Uptime: " + str(base_data.get("sysUpTime", 0))
    message += ", System Name: " + base_data.get("sysName", "")
    message += ", System Contact: " + base_data.get("sysContact", "")
    message += ", System Location: " + base_data.get("sysLocation", "")
    message += ", Company: " + model_data.get("1", "")
    message += ", Model: " + model_data.get("2", "")
    message += ", Revision: " + model_data.get("3", "")
    message += ", LSNi bus: " + lsn_status

    return {"changed": False, "msg": message,
            "data": {"state": "OK", "metrics": {}, "details": ""}}