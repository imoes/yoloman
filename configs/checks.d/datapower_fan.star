def main(ctx, params):
    fan_id_to_name = {
        "1": "CPU 1",
        "2": "CPU 2",
        "3": "Chassis 1",
        "4": "Chassis 2",
        "5": "Chassis 3",
        "6": "Chassis 4",
        "7": "Chassis 5",
        "8": "Chassis 6",
        "9": "Chassis 7",
        "10": "Chassis 8",
        "11": "Tray 1 Fan 1",
        "12": "Tray 1 Fan 2",
        "13": "Tray 1 Fan 3",
        "14": "Tray 1 Fan 4",
        "15": "Tray 2 Fan 1",
        "16": "Tray 2 Fan 2",
        "17": "Tray 2 Fan 3",
        "18": "Tray 2 Fan 4",
        "19": "Tray 3 Fan 1",
        "20": "Tray 3 Fan 2",
        "21": "Tray 3 Fan 3",
        "22": "Tray 3 Fan 4",
        "23": "Hard Disk Tray Fan 1",
        "24": "Hard Disk Tray Fan 2",
        "25": "1a",
        "26": "1b",
        "27": "2a",
        "28": "2b",
        "29": "3a",
        "30": "3b",
        "31": "4a",
        "32": "4b",
        "33": "1",
        "34": "2",
        "35": "3",
    }
    fan_state_to_txt = {
        "1": "reached lower non-recoverable limit",
        "2": "reached lower critical limit",
        "3": "reached lower non-critical limit",
        "4": "operating normally",
        "5": "reached upper non-critical limit",
        "6": "reached upper critical limit",
        "7": "reached upper non-critical critical limit",
        "8": "failure",
        "9": "no reading",
        "10": "Invalid",
    }
    fan_state_to_mon_state = {
        "1": "CRIT",
        "2": "CRIT",
        "3": "WARN",
        "4": "OK",
        "5": "WARN",
        "6": "CRIT",
        "7": "CRIT",
        "8": "CRIT",
        "9": "CRIT",
        "10": "WARN",
    }

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.14685.3.1.97.1"
    col_fan_id = base_oid + ".1"
    col_fan_speed = base_oid + ".2"
    col_fan_state = base_oid + ".4"

    # Probe for the real thing: verify the Datapower sysDescr OID exists.
    sys_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On",
                        host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_desc.rc == 127 or sys_desc.rc != 0 or not sys_desc.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "no Datapower device found",
                    "data": {"discovery": []}}
        item = params.get("item", "")
        return {"changed": False,
                "msg": "no Datapower device found for Fan %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_desc_val = sys_desc.stdout.strip()
    is_datapower = (sys_desc_val == ".1.3.6.1.4.1.14685.1.8" or
                    sys_desc_val == ".1.3.6.1.4.1.14685.1.7" or
                    sys_desc_val == ".1.3.6.1.4.1.14685.1.3")
    if not is_datapower:
        if params.get("_discover"):
            return {"changed": False, "msg": "host is not a Datapower device",
                    "data": {"discovery": []}}
        item = params.get("item", "")
        return {"changed": False,
                "msg": "host is not a Datapower device (Fan %s)" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk the fan ID column to get all fans present.
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                    host, col_fan_id], mutates=False)
    if walk.rc != 0 or not walk.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "no fans found",
                    "data": {"discovery": []}}
        item = params.get("item", "")
        return {"changed": False,
                "msg": "no fans found for Fan %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build index -> name mapping from the fan ID walk.
    fan_by_index = {}
    for line in walk.stdout.splitlines():
        space = line.find(" ")
        if space == -1:
            continue
        fan_id_oid = line[:space]
        fan_id_val = line[space + 1:].strip()
        # index is the part of the OID after the column base
        idx = fan_id_oid[len(col_fan_id) + 1:]
        name = fan_id_to_name.get(fan_id_val, fan_id_val)
        fan_by_index[idx] = {"name": name, "fan_id": fan_id_val}

    if params.get("_discover"):
        discovery = []
        for idx in sorted(fan_by_index.keys()):
            finfo = fan_by_index[idx]
            discovery.append({
                "item": finfo["name"],
                "params": {},
                "metrics": ["speed"],
            })
        return {"changed": False,
                "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    target_idx = None
    for idx in fan_by_index:
        if fan_by_index[idx]["name"] == item:
            target_idx = idx
            break
    if target_idx == None:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch speed and state for the target fan by its numeric index.
    speed_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                         host, col_fan_speed + "." + target_idx], mutates=False)
    state_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                         host, col_fan_state + "." + target_idx], mutates=False)

    speed_val = speed_res.stdout.strip() if speed_res.rc == 0 else ""
    state_code = state_res.stdout.strip() if state_res.rc == 0 else ""

    state_txt = fan_state_to_txt.get(state_code, state_code)
    mon_state = fan_state_to_mon_state.get(state_code, "UNKNOWN")

    speed_num = 0
    s = speed_val.replace('"', "")
    if s != "" and not s.startswith("no") and not s.startswith("Invalid"):
        if s.isdigit():
            speed_num = int(s)

    details = state_txt + ", " + speed_val + " rpm"
    return {"changed": False,
            "msg": "Fan %s: %s" % (item, details),
            "data": {"state": mon_state, "metrics": {"speed": speed_num},
                     "details": details}}