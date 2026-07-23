# Constants for State mapping (Starlark has no State enum, so we use strings)
OK = "OK"
WARN = "WARN"
CRIT = "CRIT"
UNKNOWN = "UNKNOWN"

def main(ctx, params):
    # DEVICE_STATES_V4 mapping (from check source)
    DEVICE_STATES_V4 = {
        0: (OK, "normal"),
        1: (CRIT, "disabled"),
        2: (CRIT, "purged"),
        5: (WARN, "reading"),
        6: (WARN, "settle"),
        7: (CRIT, "not found"),
        8: (CRIT, "lost"),
        9: (CRIT, "read error"),
        10: (CRIT, "no comm"),
        11: (CRIT, "pwr error"),
        12: (CRIT, "breaker tripped"),
        13: (CRIT, "fuse blown"),
        14: (CRIT, "low alarm"),
        15: (WARN, "low warning"),
        16: (WARN, "high warning"),
        17: (CRIT, "high alarm"),
        18: (CRIT, "alarm"),
        19: (CRIT, "under limit"),
        20: (CRIT, "over limit"),
        21: (CRIT, "nvm fail"),
        22: (CRIT, "profile error"),
        23: (CRIT, "conflict"),
    }

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.1718.4.1.8"
        ], mutates=False)

        parsed = {}
        lines = res.stdout.splitlines() if res.stdout else []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            parts = stripped.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full, value_str = parts
            oid_base = oid_full.strip()
            if ".2.1.2." in oid_base:
                outlet_id = oid_base.split(".2.1.2.")[-1]
                outlet_name = value_str.strip().strip('"')
                parsed[outlet_id] = {"name": outlet_name.replace("Outlet", "")}
            elif ".2.1.3." in oid_base:
                outlet_id = oid_base.split(".2.1.3.")[-1]
                if outlet_id in parsed:
                    parsed[outlet_id]["name"] = value_str.strip().strip('"').replace("Outlet", "")
                else:
                    parsed[outlet_id] = {"name": value_str.strip().strip('"').replace("Outlet", "")}
            elif ".3.1.2." in oid_base:
                outlet_id = oid_base.split(".3.1.2.")[-1]
                state_str = value_str.strip()
                # Guard instead of try/except
                if state_str.isdigit():
                    state_val = int(state_str)
                    if outlet_id in parsed:
                        key = "%s %s" % (outlet_id, parsed[outlet_id].get("name", ""))
                        parsed[key] = state_val
                    else:
                        parsed[outlet_id] = {"state": state_val}
                # else: skip non-integer state values

        # Build final_parsed mapping from parsed
        final_parsed = {}
        for key in parsed:
            if type(parsed[key]) == "int":
                final_parsed[key] = parsed[key]
            elif type(parsed[key]) == "dict":
                outlet_id = key
                name = parsed[outlet_id].get("name", "")
                state_val = parsed[outlet_id].get("state")
                if state_val != None:
                    final_parsed["%s %s" % (outlet_id, name)] = state_val

        # Build discovery list
        out = []
        for item in final_parsed:
            out.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d outlets" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: single item
    item = params.get("item", "")

    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.1718.4.1.8"
    ], mutates=False)

    parsed = {}
    lines = res.stdout.splitlines() if res.stdout else []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full, value_str = parts
        oid_base = oid_full.strip()
        if ".2.1.2." in oid_base:
            outlet_id = oid_base.split(".2.1.2.")[-1]
            outlet_name = value_str.strip().strip('"')
            parsed[outlet_id] = {"name": outlet_name.replace("Outlet", "")}
        elif ".2.1.3." in oid_base:
            outlet_id = oid_base.split(".2.1.3.")[-1]
            if outlet_id in parsed:
                parsed[outlet_id]["name"] = value_str.strip().strip('"').replace("Outlet", "")
            else:
                parsed[outlet_id] = {"name": value_str.strip().strip('"').replace("Outlet", "")}
        elif ".3.1.2." in oid_base:
            outlet_id = oid_base.split(".3.1.2.")[-1]
            state_str = value_str.strip()
            if state_str.isdigit():
                state_val = int(state_str)
                if outlet_id in parsed:
                    key = "%s %s" % (outlet_id, parsed[outlet_id].get("name", ""))
                    parsed[key] = state_val
                else:
                    parsed[outlet_id] = {"state": state_val}

    # Finalize parsed dict
    final_parsed = {}
    for key in parsed:
        if type(parsed[key]) == "int":
            final_parsed[key] = parsed[key]
        elif type(parsed[key]) == "dict":
            outlet_id = key
            name = parsed[outlet_id].get("name", "")
            state_val = parsed[outlet_id].get("state")
            if state_val != None:
                final_parsed["%s %s" % (outlet_id, name)] = state_val

    state_val = final_parsed.get(item)

    if state_val == None:
        return {
            "changed": False,
            "msg": "outlet not found: " + item,
            "data": {"state": UNKNOWN, "metrics": {}, "details": ""}
        }

    if state_val in DEVICE_STATES_V4:
        state_code, status = DEVICE_STATES_V4[state_val]
        state_str = state_code
    else:
        state_str = UNKNOWN
        status = "Unhandled state: " + str(state_val)

    return {
        "changed": False,
        "msg": "Status: " + status,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }