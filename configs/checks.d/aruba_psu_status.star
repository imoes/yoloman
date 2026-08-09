def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.2"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no PSU data (snmpwalk failed)",
                    "data": {"discovery": []}}
        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            column_base = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.2"
            idx = oid[len(column_base) + 1:]
            if value == "1" or value == "2":
                continue
            item_res = _fetch_psu_data(ctx, params, idx)
            if item_res == None:
                continue
            item_name = _build_item_name(item_res)
            discovery.append({
                "item": item_name,
                "params": _default_discovery_params(ctx, params),
                "metrics": ["temperature", "power"],
            })
        return {"changed": False, "msg": "discovered %d PSUs" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    state = _check_psu(ctx, params, item)
    return state

def _fetch_psu_data(ctx, params, idx):
    base = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
    oids = ["2", "3", "4", "5", "6", "7", "8", "9"]
    full_oids = []
    for col in oids:
        full_oids.append(base + "." + col + "." + idx)
    args = ["snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost")] + full_oids
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return None
    vals = res.stdout.splitlines()
    if len(vals) < len(oids):
        return None
    data = {}
    data["state"] = vals[0]
    data["failures"] = int(vals[1]) if vals[1].isdigit() else 0
    data["temperature"] = float(vals[2]) if _is_float(vals[2]) else 0.0
    data["voltage_info"] = vals[3]
    data["wattage_curr"] = int(vals[3 + 2]) if vals[3 + 2].lstrip("-").isdigit() else 0
    data["wattage_max"] = int(vals[3 + 3]) if vals[3 + 3].lstrip("-").isdigit() else 0
    data["last_call"] = int(vals[3 + 4]) if vals[3 + 4].lstrip("-").isdigit() else 0
    data["model"] = vals[3 + 5]
    return data

def _is_float(v):
    parts = v.split(".")
    if len(parts) == 1:
        return parts[0].lstrip("-").isdigit()
    if len(parts) == 2:
        return parts[0].lstrip("-").isdigit() and parts[1].isdigit()
    return False

def _build_item_name(data):
    return data["model"] + " " + data["state"]

def _default_discovery_params(ctx, params):
    temp_params = {}
    temp_levels = params.get("temperature_levels")
    if temp_levels == None:
        temp_params["levels"] = (50.0, 60.0)
    else:
        temp_params["levels"] = temp_levels
    watt_params = {}
    watt_abs = params.get("levels_abs_upper")
    if watt_abs == None:
        watt_params["levels_abs_upper"] = (500.0, 600.0)
    else:
        watt_params["levels_abs_upper"] = watt_abs
    return {"temperature": temp_params, "wattage": watt_params}

def _check_psu(ctx, params, item):
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                    "-Oqn", params.get("host", "localhost"),
                    ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.9"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no PSU data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    target_idx = None
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        column_base = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.9"
        idx = oid[len(column_base) + 1:]
        if value + " " + idx == item or value.strip() == item.split()[0] if _safe_split(item) else "":
            if item.startswith(value):
                target_idx = idx
                break
    if target_idx == None:
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            column_base = ".1.3.6.1.4.1.11.2.14.11.5.1.1.1.9"
            idx = oid[len(column_base) + 1:]
            if value + " " + (idx) == item:
                target_idx = idx
                break
    if target_idx == None:
        return {"changed": False, "msg": "no such PSU: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = _fetch_psu_data(ctx, params, target_idx)
    if data == None:
        return {"changed": False, "msg": "failed to read PSU data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state_map = {
        "1": "OK", "2": "OK", "3": "OK", "4": "CRIT",
        "5": "CRIT", "6": "OK", "7": "CRIT", "8": "CRIT", "9": "CRIT",
    }
    ps_state = state_map.get(data["state"], "UNKNOWN")
    state_names = {
        "1": "NotPresent", "2": "NotPlugged", "3": "Powered",
        "4": "Failed", "5": "PermFailure", "6": "Max",
        "7": "AuxFailure", "8": "NotPowered", "9": "AuxNotPowered",
    }
    state_name = state_names.get(data["state"], "Unknown")
    metrics = {}
    metrics["temperature"] = data["temperature"]
    metrics["power"] = data["wattage_curr"]
    metrics["failures"] = data["failures"]
    temp_params = params.get("temperature", {})
    temp_levels = temp_params.get("levels", (50.0, 60.0))
    temp_state = _check_temperature(data["temperature"], temp_levels)
    if ps_state == "CRIT":
        final_state = "CRIT"
    elif temp_state == "WARN":
        final_state = "WARN"
    elif temp_state == "CRIT":
        final_state = "CRIT"
    else:
        final_state = ps_state
    watt_params = params.get("wattage", {})
    watt_abs = watt_params.get("levels_abs_upper", (500.0, 600.0))
    watt_curr = data["wattage_curr"]
    if watt_curr >= watt_abs[1]:
        final_state = "CRIT"
    elif watt_curr >= watt_abs[0]:
        final_state = "WARN"
    msg = "PSU Status: %s" % state_name
    return {"changed": False, "msg": msg,
            "data": {"state": final_state, "metrics": metrics,
                     "details": "Temperature: %fC, Wattage: %dW/%dW, Voltage: %s, Uptime: %ds" % (
                         data["temperature"], data["wattage_curr"], data["wattage_max"],
                         data["voltage_info"], data["last_call"])}}

def _check_temperature(temp, levels):
    warn, crit = levels[0], levels[1]
    if temp >= crit:
        return "CRIT"
    if temp >= warn:
        return "WARN"
    return "OK"

def _safe_split(s):
    parts = s.split(" ")
    return len(parts) >= 1