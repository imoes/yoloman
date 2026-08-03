def main(ctx, params):
    if params.get("_discover"):
        # Probe that this is really a Huawei switch
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                           "-Oqv", params.get("host", "localhost"),
                           ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0 or sys_oid.rc == 127:
            return {"changed": False, "msg": "Huawei switch not detected",
                    "data": {"discovery": []}}
        sys_val = sys_oid.stdout.strip()
        if not sys_val.startswith(".1.3.6.1.4.1.2011.2.23"):
            return {"changed": False, "msg": "Not a Huawei switch",
                    "data": {"discovery": []}}

        # Fetch entPhysicalDescr entries (first SNMPTree)
        descr_walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                              "-Oqn", params.get("host", "localhost"),
                              ".1.3.6.1.2.1.47.1.1.1.1.7"], mutates=False)
        if descr_walk.rc != 0 or descr_walk.rc == 127:
            return {"changed": False, "msg": "cannot fetch entity descr",
                    "data": {"discovery": []}}

        # Fetch entPhysicalClass values (second SNMPTree via .2)
        class_walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                              "-Oqn", params.get("host", "localhost"),
                              ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.2"], mutates=False)
        if class_walk.rc != 0 or class_walk.rc == 127:
            return {"changed": False, "msg": "cannot fetch entity class",
                    "data": {"discovery": []}}

        # Build value lookup by index
        value_by_index = {}
        for line in class_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[oid.rfind(".") + 1:]
            value_by_index[idx] = parts[1].strip()

        # Discover power cards and assign item names
        stack_member = 0
        entities = {}
        order = []
        for line in descr_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[oid.rfind(".") + 1:]
            descr = parts[1].strip()
            lower_descr = descr.lower()
            if lower_descr.startswith("mpu board"):
                stack_member += 1
            if lower_descr.startswith("power card"):
                idx_in_member = 0
                for line2 in descr_walk.stdout.splitlines():
                    p2 = line2.split(" ", 1)
                    if len(p2) < 2:
                        continue
                    d2 = p2[1].strip().lower()
                    if d2.startswith("power card") and d2 < lower_descr:
                        idx_in_member += 1
                item_name = str(stack_member) + "/" + str(idx_in_member + 1)
                entities[item_name] = value_by_index.get(idx)
                order.append(item_name)

        discovery = []
        for item_name in order:
            discovery.append({"item": item_name, "params": {},
                              "metrics": ["oper_state"]})
        return {"changed": False,
                "msg": "discovered %d PSUs" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    # Re-fetch data for the specific item
    descr_walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-Oqn", params.get("host", "localhost"),
                          ".1.3.6.1.2.1.47.1.1.1.1.7"], mutates=False)
    class_walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-Oqn", params.get("host", "localhost"),
                          ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.2"], mutates=False)
    if descr_walk.rc != 0 or class_walk.rc != 0 or descr_walk.rc == 127 or class_walk.rc == 127:
        return {"changed": False, "msg": "cannot fetch SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_by_index = {}
    for line in class_walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[oid.rfind(".") + 1:]
        value_by_index[idx] = parts[1].strip()

    stack_member = 0
    target_idx = None
    item_parts = item.split("/")
    target_member = int(item_parts[0]) if item_parts[0].isdigit() else 0
    target_sub = int(item_parts[1]) if len(item_parts) > 1 and item_parts[1].isdigit() else 0

    current_member = 0
    sub = 0
    for line in descr_walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[oid.rfind(".") + 1:]
        descr = parts[1].strip()
        lower_descr = descr.lower()
        if lower_descr.startswith("mpu board"):
            current_member += 1
            sub = 0
        if lower_descr.startswith("power card"):
            if current_member == target_member and sub == target_sub:
                target_idx = idx
                break
            sub += 1

    if target_idx == None:
        return {"changed": False, "msg": "no such PSU: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_val = value_by_index.get(target_idx)
    if raw_val == None:
        return {"changed": False, "msg": "no value for PSU: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_map = {"1": "notSupported", "2": "disabled", "3": "enabled", "4": "offline"}
    status_text = state_map.get(raw_val, "unknown (" + raw_val + ")")
    state = "OK" if raw_val == "3" else "CRIT"
    return {"changed": False,
            "msg": "State: " + status_text,
            "data": {"state": state, "metrics": {"oper_state": 1 if raw_val == "3" else 0},
                     "details": ""}}