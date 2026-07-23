def main(ctx, params):
    # SNMP parameters with Checkmk defaults
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    # Discovery mode: enumerate items
    if params.get("_discover"):
        # Both models share the same alarm item names: "1" and "2"
        return {
            "changed": False,
            "msg": "discovered 2 alarm detectors",
            "data": {
                "discovery": [
                    {"item": "1", "params": {}, "metrics": []},
                    {"item": "2", "params": {}, "metrics": []},
                ]
            },
        }

    # Probe: fetch both SNMPTree base sections for the alarm detector logic
    # Section 0: sysName, sysUpTime, sysContact, sysLocation, sysDescr
    # Section 1: Model-specific alarm section (.1.3.6.1.4.1.34187.21501.1.1 or .74195.1.1)
    # We fetch all OIDs as strings and parse them in Python
    base1 = ".1.3.6.1.2.1.1"
    oids1 = ["1", "3", "4", "5", "6"]
    tree1 = [base1 + "." + o for o in oids1]
    
    # Detect model by sysOID and fetch corresponding alarm tree
    res_oid = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res_oid.rc != 0:
        return {"changed": False, "msg": "snmpget sysOID failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_oid = res_oid.stdout.strip().split()[-1] if len(res_oid.stdout.strip().split()) > 1 else ""
    
    base2 = None
    if sys_oid == ".1.3.6.1.4.1.34187.21501":
        base2 = ".1.3.6.1.4.1.34187.21501.1.1"
    elif sys_oid == ".1.3.6.1.4.1.34187.74195":
        base2 = ".1.3.6.1.4.1.34187.74195.1.1"
    else:
        return {"changed": False, "msg": "unsupported model", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    oids2 = ["1", "2", "3", "1000", "1001", "1002", "1003", "1004", "1005", "1006"]
    tree2 = [base2 + "." + o for o in oids2]
    
    # Fetch both trees using snmpwalk
    res_tree1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + tree1, mutates=False)
    res_tree2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + tree2, mutates=False)
    if res_tree1.rc != 0 or res_tree2.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output into lists of (oid, value) pairs
    def parse_snmp_out(output):
        result = {}
        for line in output.strip().splitlines():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                oid_part = parts[0].strip()
                val_part = parts[1].strip()
                result[oid_part] = val_part
        return result
    
    tree1_data = parse_snmp_out(res_tree1.stdout)
    tree2_data = parse_snmp_out(res_tree2.stdout)
    
    # Extract model alarm fields: indices 3,4,5,6,7,8 (0-based) correspond to items "1" and "2"
    # item 1 -> indices [3,4,5], item 2 -> indices [6,7,8]
    # OIDs end with ".1000",".1001",...".1006"
    def get_val(prefix, idx):
        oid = prefix + "." + str(idx)
        return tree2_data.get(oid, "")
    
    prefix = base2
    if item == "1":
        main_alarm = get_val(prefix, "1003")
        pre_alarm = get_val(prefix, "1004")
        info_alarm = get_val(prefix, "1005")
    elif item == "2":
        main_alarm = get_val(prefix, "1006")
        pre_alarm = get_val(prefix, "1007")
        info_alarm = get_val(prefix, "1008")
    else:
        return {"changed": False, "msg": "Alarm Detector %s not found in SNMP" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Evaluate alarm states: main > pre > info priority
    state = "OK"
    message = "No Alarm"
    if info_alarm != "0":
        message = "Info Alarm"
        state = "WARN"
    if pre_alarm != "0":
        message = "Pre Alarm"
        state = "WARN"
    if main_alarm != "0":
        message = "Main Alarm: Fire"
        state = "CRIT"
    
    return {"changed": False, "msg": message,
            "data": {"state": state, "metrics": {}, "details": ""}}