_OPENBSD_MAP_STATE = {
    "0": "UNKNOWN",
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
}

_OPENBSD_MAP_TYPE = {
    "0": "temp",
    "1": "fan",
    "2": "voltage",
    "9": "indicator",
    "13": "drive",
    "21": "powersupply",
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.30155.2.1.2.1"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        used_descriptions = []
        data_by_idx = {}
        
        def get_item_name(name):
            idx = 0
            new_name = name
            while True:
                if new_name in used_descriptions:
                    new_name = name + "/" + str(idx)
                    idx += 1
                else:
                    used_descriptions.append(new_name)
                    break
            return new_name
        
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0]
            value_part = parts[1]
            val_type_val = value_part.split(": ", 1)
            if len(val_type_val) != 2:
                continue
            val_type, val = val_type_val
            base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
            if not oid_val.startswith(base_oid + "."):
                continue
            suffix = oid_val[len(base_oid) + 1:]
            parts2 = suffix.split(".")
            if len(parts2) < 2:
                continue
            idx_str = parts2[0]
            field_idx_str = parts2[1]
            if not idx_str.isdigit() or not field_idx_str.isdigit():
                continue
            idx = int(idx_str)
            field = int(field_idx_str)
            if idx == 0:
                continue
            if idx not in data_by_idx:
                data_by_idx[idx] = {}
            data_by_idx[idx][field] = val.strip()
        
        section = {}
        for idx, fields in data_by_idx.items():
            if not (2 in fields and 3 in fields and 5 in fields and 6 in fields and 7 in fields):
                continue
            descr = fields[2]
            sensortype = fields[3]
            value = fields[5]
            unit = fields[6]
            state = fields[7]
            if sensortype not in _OPENBSD_MAP_TYPE:
                continue
            # Skip invalid values
            if (sensortype == "0" and value == "-273.15") or (sensortype in ["1", "2"] and value == "0"):
                continue
            value_converted = float(value) if value.replace(".", "", 1).lstrip("-").isdigit() else value
            item_name = get_item_name(descr)
            section[item_name] = {
                "state": _OPENBSD_MAP_STATE.get(state, "UNKNOWN"),
                "value": value_converted,
                "unit": unit,
                "type": _OPENBSD_MAP_TYPE[sensortype],
            }
        
        out = []
        for key, values in section.items():
            if values["type"] == "drive":
                out.append({
                    "item": key,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d drive sensors" % len(out),
            "data": {"discovery": out}
        }
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.30155.2.1.2.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    used_descriptions = []
    data_by_idx = {}
    
    def get_item_name_v2(name):
        idx = 0
        new_name = name
        while True:
            if new_name in used_descriptions:
                new_name = name + "/" + str(idx)
                idx += 1
            else:
                used_descriptions.append(new_name)
                break
        return new_name
    
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_val = parts[0]
        value_part = parts[1]
        val_type_val = value_part.split(": ", 1)
        if len(val_type_val) != 2:
            continue
        val_type, val = val_type_val
        base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
        if not oid_val.startswith(base_oid + "."):
            continue
        suffix = oid_val[len(base_oid) + 1:]
        parts2 = suffix.split(".")
        if len(parts2) < 2:
            continue
        idx_str = parts2[0]
        field_idx_str = parts2[1]
        if not idx_str.isdigit() or not field_idx_str.isdigit():
            continue
        idx = int(idx_str)
        field = int(field_idx_str)
        if idx == 0:
            continue
        if idx not in data_by_idx:
            data_by_idx[idx] = {}
        data_by_idx[idx][field] = val.strip()
    
    section = {}
    for idx, fields in data_by_idx.items():
        if not (2 in fields and 3 in fields and 5 in fields and 6 in fields and 7 in fields):
            continue
        descr = fields[2]
        sensortype = fields[3]
        value = fields[5]
        unit = fields[6]
        state = fields[7]
        if sensortype not in _OPENBSD_MAP_TYPE:
            continue
        if (sensortype == "0" and value == "-273.15") or (sensortype in ["1", "2"] and value == "0"):
            continue
        value_converted = float(value) if value.replace(".", "", 1).lstrip("-").isdigit() else value
        item_name = get_item_name_v2(descr)
        section[item_name] = {
            "state": _OPENBSD_MAP_STATE.get(state, "UNKNOWN"),
            "value": value_converted,
            "unit": unit,
            "type": _OPENBSD_MAP_TYPE[sensortype],
        }
    
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no such drive sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state = data["state"]
    value = data["value"]
    
    summary = "Status: " + str(value)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }