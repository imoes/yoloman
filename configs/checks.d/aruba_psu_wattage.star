def _level_state(value, warn, crit):
    if warn == None and crit == None:
        return "OK"
    if warn == None:
        return "CRIT" if value >= crit else "OK"
    if crit == None:
        return "WARN" if value >= warn else "OK"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        sys_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                           params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sys_res.rc == 127 or sys_res.stdout == "":
            return {"changed": False, "msg": "Aruba device not present",
                    "data": {"discovery": [], "host_labels": {}}}
        sys_val = sys_res.stdout
        if not (sys_val.startswith("Aruba") and "2930M" in sys_val):
            return {"changed": False, "msg": "Aruba 2930M not detected",
                    "data": {"discovery": [], "host_labels": {}}}
        walk_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                            "-Oqn", params.get("host", "localhost"),
                            ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"], mutates=False)
        if walk_res.rc == 127 or not walk_res.stdout:
            return {"changed": False, "msg": "no PSUs found",
                    "data": {"discovery": [], "host_labels": {}}}
        base_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
        entries = {}
        for line in walk_res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) < 2:
                continue
            oid = sp[0]
            val = sp[1]
            suffix = oid[len(base_oid):]
            parts = suffix.split(".")
            if len(parts) < 2:
                continue
            idx = parts[1]
            col = parts[0]
            if idx not in entries:
                entries[idx] = {}
            entries[idx][col] = val
        discovery = []
        for idx in sorted(entries.keys()):
            cols = entries[idx]
            model = cols.get("9", "")
            state_raw = cols.get("2", "")
            if state_raw == "1" or state_raw == "2":
                continue
            model_str = cols.get("9", "")
            item_name = model_str + " " + model_str if model_str else model_str
            discovery.append({"item": item_name,
                              "params": {"levels_abs_upper": None,
                                         "levels_abs_lower": None,
                                         "levels_perc_upper": [80.0, 90.0],
                                         "levels_perc_lower": [0.0, 0.0]},
                              "metrics": ["power", "wattage_percent"]})
        return {"changed": False, "msg": "discovered %d PSUs" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/dev/Aruba2930M": True}}}

    item = params.get("item", "")
    base_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sys_res = ctx.run(["snmpget", "-v2c", "-c", community, host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sys_res.rc == 127 or sys_res.stdout == "":
        return {"changed": False, "msg": "Aruba device not present",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no Aruba SNMP device found"}}
    sys_val = sys_res.stdout
    if not (sys_val.startswith("Aruba") and "2930M" in sys_val):
        return {"changed": False, "msg": "Aruba 2930M not detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "not an Aruba 2930M device"}}

    if item == "":
        return {"changed": False, "msg": "no PSU item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no PSU item specified"}}

    item_model = item
    walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid], mutates=False)
    if walk_res.rc == 127 or not walk_res.stdout:
        return {"changed": False, "msg": "no PSUs found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no PSU SNMP data"}}

    entries = {}
    for line in walk_res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        oid = sp[0]
        val = sp[1]
        suffix = oid[len(base_oid):]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        idx = parts[1]
        col = parts[0]
        if idx not in entries:
            entries[idx] = {}
        entries[idx][col] = val

    target_idx = None
    for idx in entries:
        model_val = entries[idx].get("9", "")
        if model_val == item_model:
            target_idx = idx
            break
    if target_idx == None:
        return {"changed": False, "msg": "PSU not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "PSU item not found in section"}}

    psu = entries[target_idx]
    state_raw = psu.get("2", "")
    if state_raw == "1" or state_raw == "2":
        return {"changed": False, "msg": "PSU " + item + " not present",
                "data": {"state": "OK", "metrics": {}, "details": "PSU NotPresent/NotPlugged"}}

    state_map = {"1": "OK", "2": "OK", "3": "OK", "4": "CRIT", "5": "CRIT",
                 "6": "OK", "7": "CRIT", "8": "CRIT", "9": "CRIT"}
    psu_state = state_map.get(state_raw, "UNKNOWN")
    state_name = {"1": "NotPresent", "2": "NotPlugged", "3": "Powered",
                  "4": "Failed", "5": "PermFailure", "6": "Max",
                  "7": "AuxFailure", "8": "NotPowered", "9": "AuxNotPowered"}.get(state_raw, "Unknown")

    wattage_curr = int(psu.get("6", "0")) if psu.get("6", "0").isdigit() else 0
    wattage_max = int(psu.get("7", "0")) if psu.get("7", "0").isdigit() else 0
    voltage_info = psu.get("5", "")
    last_call = int(psu.get("8", "0")) if psu.get("8", "0").isdigit() else 0

    abs_w = params.get("levels_abs_upper")
    if type(abs_w) == "list" and len(abs_w) >= 2:
        warn_abs = abs_w[0]
        crit_abs = abs_w[1]
    else:
        warn_abs = 500.0
        crit_abs = 600.0

    abs_state = "OK"
    if psu_state != "CRIT":
        abs_state = _level_state(wattage_curr, warn_abs, crit_abs)

    pct_state = "OK"
    wattage_pct = 0.0
    if wattage_max > 0:
        wattage_pct = wattage_curr / wattage_max * 100.0
        pct_w = params.get("levels_perc_upper")
        if type(pct_w) == "list" and len(pct_w) >= 2:
            warn_pct = pct_w[0]
            crit_pct = pct_w[1]
        else:
            warn_pct = 80.0
            crit_pct = 90.0
        pct_state = _level_state(wattage_pct, warn_pct, crit_pct)

    final_state = "CRIT" if (abs_state == "CRIT" or pct_state == "CRIT") else ("WARN" if (abs_state == "WARN" or pct_state == "WARN") else psu_state)

    msg = "PSU Status: %s, Wattage: %fW (%f%% of %fW max)" % (state_name, wattage_curr, wattage_pct, wattage_max)
    details = "Voltage Info: %s\nUptime: %ds" % (voltage_info, last_call)

    return {"changed": False, "msg": msg,
            "data": {"state": final_state,
                     "metrics": {"power": wattage_curr, "wattage_percent": wattage_pct},
                     "details": details}}