def main(ctx, params):
    if params.get("_discover"):
        # SNMP walk the brocade_mlx_fan table: base OID .1.3.6.1.4.1.1991.1.1.1.3.1.1 with OIDs 1,2,3
        base_oid = ".1.3.6.1.4.1.1991.1.1.1.3.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid + ".1", base_oid + ".2", base_oid + ".3"
        ], mutates=False)
        
        # Parse snmpwalk output into fan entries
        # Format: OID = STRING: value per line, e.g.:
        # .1.3.6.1.4.1.1991.1.1.1.3.1.1.1.1 = STRING: "1"
        # .1.3.6.1.4.1.1991.1.1.1.3.1.1.2.1 = STRING: "Fan 1"
        # .1.3.6.1.4.1.1991.1.1.1.3.1.1.3.1 = STRING: "1"
        
        # Group by fan index (last number after last dot)
        fans = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid, value = parts
            if not value.startswith("STRING: "):
                continue
            val = value[8:].strip().strip('"')
            # Extract index from OID: .1.3.6.1.4.1.1991.1.1.1.3.1.1.{oid_num}.{index}
            oid_parts = oid.rsplit(".", 1)
            if len(oid_parts) != 2:
                continue
            index_str = oid_parts[1]
            if not index_str.isdigit():
                continue
            index = int(index_str)
            oid_num_str = oid_parts[0].rsplit(".", 1)
            if len(oid_num_str) != 2:
                continue
            oid_num_part = oid_num_str[1]
            if not oid_num_part.isdigit():
                continue
            oid_num = int(oid_num_part)
            if index not in fans:
                fans[index] = {"id": "", "descr": "", "state": ""}
            if oid_num == 1:
                fans[index]["id"] = val
            elif oid_num == 2:
                fans[index]["descr"] = val
            elif oid_num == 3:
                fans[index]["state"] = val
        
        # Build discovery list: only include fans where state != "1" (not present)
        discovery = []
        for idx in sorted(fans.keys()):
            fan = fans[idx]
            if fan["state"] != "1":  # Only add fans who are present
                item = fan["id"]
                if fan["descr"] != "" and "(RPM " not in fan["descr"]:
                    item = fan["id"] + " " + fan["descr"]
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode: single item
    item = params.get("item", "")
    # Re-fetch the same SNMP data
    base_oid = ".1.3.6.1.4.1.1991.1.1.1.3.1.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base_oid + ".1", base_oid + ".2", base_oid + ".3"
    ], mutates=False)
    
    # Parse fans again
    fans = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        if not value.startswith("STRING: "):
            continue
        val = value[8:].strip().strip('"')
        oid_parts = oid.rsplit(".", 1)
        if len(oid_parts) != 2:
            continue
        index_str = oid_parts[1]
        if not index_str.isdigit():
            continue
        index = int(index_str)
        oid_num_str = oid_parts[0].rsplit(".", 1)
        if len(oid_num_str) != 2:
            continue
        oid_num_part = oid_num_str[1]
        if not oid_num_part.isdigit():
            continue
        oid_num = int(oid_num_part)
        if index not in fans:
            fans[index] = {"id": "", "descr": "", "state": ""}
        if oid_num == 1:
            fans[index]["id"] = val
        elif oid_num == 2:
            fans[index]["descr"] = val
        elif oid_num == 3:
            fans[index]["state"] = val
    
    # Find matching fan
    found = False
    for idx in sorted(fans.keys()):
        fan = fans[idx]
        fan_item = fan["id"]
        if fan["descr"] != "" and "(RPM " not in fan["descr"]:
            fan_item = fan["id"] + " " + fan["descr"]
        if fan_item == item:
            found = True
            state = fan["state"]
            if state == "2":
                return {
                    "changed": False,
                    "msg": "Fan reports state: normal",
                    "data": {
                        "state": "OK",
                        "metrics": {},
                        "details": ""
                    }
                }
            elif state == "3":
                return {
                    "changed": False,
                    "msg": "Fan reports state: failure",
                    "data": {
                        "state": "CRIT",
                        "metrics": {},
                        "details": ""
                    }
                }
            elif state == "1":
                return {
                    "changed": False,
                    "msg": "Fan reports state: other",
                    "data": {
                        "state": "UNKNOWN",
                        "metrics": {},
                        "details": ""
                    }
                }
            else:
                return {
                    "changed": False,
                    "msg": "Fan reports an unhandled state (%s)" % state,
                    "data": {
                        "state": "UNKNOWN",
                        "metrics": {},
                        "details": ""
                    }
                }
    
    # Fan not found
    if not found:
        return {
            "changed": False,
            "msg": "Fan not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
