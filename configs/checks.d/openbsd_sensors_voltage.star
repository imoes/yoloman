def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid + ".2", base_oid + ".3", base_oid + ".5", base_oid + ".6", base_oid + ".7"
        ], mutates=False)
        
        lines = res.stdout.splitlines() if res.stdout else []
        data_by_index = {}
        for line in lines:
            if not line.strip():
                continue
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx+1:].strip()
            parts = oid_part.split(".")
            if len(parts) < 2:
                continue
            try_idx = -1
            last_idx = -1
            for i in range(len(parts)-1, -1, -1):
                if parts[i].isdigit():
                    last_idx = i
                    if try_idx == -1:
                        try_idx = i
            if try_idx == -1:
                continue
            idx = int(parts[try_idx])
            field_idx = int(parts[try_idx-1]) if try_idx > 0 else -1
            if idx not in data_by_index:
                data_by_index[idx] = {}
            if field_idx == 2:
                data_by_index[idx]["descr"] = value_part
            elif field_idx == 3:
                data_by_index[idx]["sensortype"] = value_part
            elif field_idx == 5:
                data_by_index[idx]["value"] = value_part
            elif field_idx == 6:
                data_by_index[idx]["unit"] = value_part
            elif field_idx == 7:
                data_by_index[idx]["state"] = value_part

        discovered = []
        for idx, entry in data_by_index.items():
            sensortype = entry.get("sensortype", "")
            if sensortype != "2":
                continue
            value_str = entry.get("value", "")
            descr = entry.get("descr", "unknown")
            if value_str == "":
                continue
            if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                if int(value_str) == 0:
                    continue
            else:
                if value_str.replace(".", "").replace("-", "", 1).isdigit():
                    if float(value_str) == 0:
                        continue
                else:
                    continue

            discovered.append({
                "item": descr,
                "params": {},
                "metrics": ["voltage"]
            })

        return {"changed": False,
                "msg": "discovered %d voltage sensors" % len(discovered),
                "data": {"discovery": discovered}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid + ".2", base_oid + ".3", base_oid + ".5", base_oid + ".6", base_oid + ".7"
    ], mutates=False)

    lines = res.stdout.splitlines() if res.stdout else []
    data_by_index = {}
    for line in lines:
        if not line.strip():
            continue
        eq_idx = line.find("=")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx+1:].strip()
        parts = oid_part.split(".")
        if len(parts) < 2:
            continue
        try_idx = -1
        for i in range(len(parts)-1, -1, -1):
            if parts[i].isdigit():
                last_idx = i
                if try_idx == -1:
                    try_idx = i
        if try_idx == -1:
            continue
        idx = int(parts[try_idx])
        field_idx = int(parts[try_idx-1]) if try_idx > 0 else -1
        if idx not in data_by_index:
            data_by_index[idx] = {}
        if field_idx == 2:
            data_by_index[idx]["descr"] = value_part
        elif field_idx == 3:
            data_by_index[idx]["sensortype"] = value_part
        elif field_idx == 5:
            data_by_index[idx]["value"] = value_part
        elif field_idx == 6:
            data_by_index[idx]["unit"] = value_part
        elif field_idx == 7:
            data_by_index[idx]["state"] = value_part

    data = None
    for idx, entry in data_by_index.items():
        if entry.get("sensortype") == "2" and entry.get("descr") == item:
            data = entry
            break

    if data == None:
        return {"changed": False,
                "msg": "voltage sensor '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_str = data.get("value", "")
    value = 0.0
    if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
        value = float(value_str)
    elif value_str.replace(".", "").replace("-", "", 1).isdigit():
        value = float(value_str)
    else:
        return {"changed": False,
                "msg": "cannot parse voltage value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    msg = "Voltage: %s V" % value_str

    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {"voltage": value}, "details": ""}}