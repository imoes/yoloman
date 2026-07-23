def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.19746.1.2.3.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1", base_oid + ".2", base_oid + ".3", base_oid + ".4"
        ], mutates=False)
        # Parse snmpwalk output lines like:
        # .1.3.6.1.4.1.19746.1.2.3.1.1.1.1.1 = STRING: "1"
        # .1.3.6.1.4.1.19746.1.2.3.1.1.1.1.2 = STRING: "1"
        # .1.3.6.1.4.1.19746.1.2.3.1.1.1.1.3 = INTEGER: 0
        # .1.3.6.1.4.1.19746.1.2.3.1.1.1.1.4 = INTEGER: 100
        items = []
        index = -1
        index_str = ""
        name = ""
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Split OID and value parts
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            # Extract value and strip type prefix (e.g., "STRING: ", "INTEGER: ")
            if ": " in value_part:
                value_type, value = value_part.split(": ", 1)
                value = value.strip().strip('"')
            else:
                value = value_part.strip().strip('"')
            # Determine OID suffix
            suffix = oid_full.rsplit(".", 1)[-1]
            # Map suffix to field: 1->index, 2->name, 3->state, 4->charge
            if suffix == "1":
                index_str = value
            elif suffix == "2":
                name = value
            elif suffix == "3":
                # We now have index and name, can form item
                if index_str and name:
                    item_name = index_str + "-" + name
                    items.append({
                        "item": item_name,
                        "params": {},
                        "metrics": ["battery_capacity"]
                    })
        return {"changed": False, "msg": "discovered %d NVRAM batteries" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.19746.1.2.3.1.1"
    # Query all fields in one walk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".2", base_oid + ".3", base_oid + ".4"
    ], mutates=False)
    state_table = {
        "0": ("OK", "OK"),
        "1": ("Disabled", "WARN"),
        "2": ("Discharged", "CRIT"),
        "3": ("Softdisabled", "WARN"),
    }
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        if ": " in value_part:
            value_type, value = value_part.split(": ", 1)
            value = value.strip().strip('"')
        else:
            value = value_part.strip().strip('"')
        # Build item from index (field .1) and name (field .2)
        suffix = oid_full.rsplit(".", 1)[-1]
        if suffix == "1":
            index_str = value
        elif suffix == "2":
            name = value
        elif suffix == "3":
            state = value
        elif suffix == "4":
            charge = value
            # Form item and check
            item_name = index_str + "-" + name
            if item_name == item:
                state_str, state_level = state_table.get(state, ("Unknown", "UNKNOWN"))
                # Map state_level to Checkmk states
                if state_level == "OK":
                    state_num = 0
                elif state_level == "WARN":
                    state_num = 1
                elif state_level == "CRIT":
                    state_num = 2
                else:
                    state_num = 3
                return {
                    "changed": False,
                    "msg": "Status %s Charge Level %s%%" % (state_str, charge),
                    "data": {
                        "state": state_level,
                        "metrics": {"battery_capacity": float(charge) if charge.isdigit() else 0.0},
                        "details": ""
                    }
                }
    # Item not found
    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
