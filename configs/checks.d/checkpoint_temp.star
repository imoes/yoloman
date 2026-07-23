def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.2620.1.6.7.8.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        lines = res.stdout.splitlines() if res.stdout else []
        table = {}
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            if not oid_part.startswith(base_oid + "."):
                continue
            rest = oid_part[len(base_oid) + 1:]
            if "." not in rest:
                continue
            idx_str = rest.split(".")[0]
            col = rest.split(".")[1] if "." in rest else ""
            if idx_str not in table:
                table[idx_str] = {"name": "", "value": "", "unit": "", "dev_status": ""}
            if col == "2":
                val = val_part
                if val.startswith("STRING: "):
                    val = val[len("STRING: "):]
                elif val.startswith("TEXT: "):
                    val = val[len("TEXT: "):]
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                table[idx_str]["name"] = val
            elif col == "3":
                table[idx_str]["value"] = val_part
            elif col == "4":
                table[idx_str]["unit"] = val_part
            elif col == "6":
                table[idx_str]["dev_status"] = val_part
        items = []
        for idx_str, row in table.items():
            name = row["name"]
            if not name:
                continue
            item = name.upper().replace(" TEMP", "")
            items.append({"item": item, "params": {"levels": [50.0, 60.0]},
                          "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.2620.1.6.7.8.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    table = {}
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        if not oid_part.startswith(base_oid + "."):
            continue
        rest = oid_part[len(base_oid) + 1:]
        if "." not in rest:
            continue
        idx_str = rest.split(".")[0]
        col = rest.split(".")[1] if "." in rest else ""
        if idx_str not in table:
            table[idx_str] = {"name": "", "value": "", "unit": "", "dev_status": ""}
        if col == "2":
            val = val_part
            if val.startswith("STRING: "):
                val = val[len("STRING: "):]
            elif val.startswith("TEXT: "):
                val = val[len("TEXT: "):]
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            table[idx_str]["name"] = val
        elif col == "3":
            table[idx_str]["value"] = val_part
        elif col == "4":
            table[idx_str]["unit"] = val_part
        elif col == "6":
            table[idx_str]["dev_status"] = val_part
    
    found = False
    state = "UNKNOWN"
    state_readable = "no matching sensor"
    value = ""
    unit = "c"
    dev_status = "0"
    for idx_str, row in table.items():
        name = row["name"]
        if not name:
            continue
        if name.upper().replace(" TEMP", "") == item:
            found = True
            dev_status = row["dev_status"]
            value = row["value"]
            unit = row["unit"]
            break
    
    status_map = {
        "0": ("OK", "sensor in range"),
        "1": ("CRIT", "sensor out of range"),
        "2": ("UNKNOWN", "reading error"),
    }
    status_tuple = status_map.get(dev_status, ("UNKNOWN", "unknown status"))
    state = status_tuple[0]
    state_readable = status_tuple[1]
    
    if not found:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if value == "":
        return {"changed": False, "msg": "Status: " + state_readable,
                "data": {"state": state, "metrics": {}, "details": ""}}
    
    temp_value = 0.0
    if value.isdigit() or (value.startswith("-") and value[1:].isdigit()) or ("." in value and value.replace("-", "").replace(".", "").isdigit()):
        temp_value = float(value)
    else:
        return {"changed": False, "msg": "cannot parse temperature value: " + value,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    unit = unit.replace("degree", "").strip().lower()
    if unit.startswith("f") or unit == "fahrenheit":
        unit = "f"
    else:
        unit = "c"
    
    levels = params.get("levels", [50.0, 60.0])
    warn = levels[0]
    crit = levels[1]
    
    if temp_value >= crit:
        state = "CRIT"
    elif temp_value >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Status: " + state_readable + ", Temperature: %f " % temp_value + unit
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp_value},
            "details": "",
        },
    }
