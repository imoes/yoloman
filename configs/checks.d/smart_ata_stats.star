def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _probe_smartctl(ctx):
    res = ctx.run(["smartctl", "--version"], mutates=False)
    return res.rc == 0


def _get_devices(ctx):
    if not _probe_smartctl(ctx):
        return {}
    res = ctx.run(["smartctl", "--scan"], mutates=False)
    devices = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            dev = parts[0]
            if parts[1] == "-d":
                dtype = parts[2] if len(parts) >= 3 else "ata"
            else:
                dtype = "ata"
            devices[dev] = dtype
    return devices


def _get_smart_json(ctx, dev, dtype):
    args = ["smartctl", "-a", "-j"]
    if dtype != "ata":
        args = ["smartctl", "-d", dtype, "-a", "-j"]
    args = args + [dev]
    res = ctx.run(args, mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return None
    return json.decode(res.stdout) if res.stdout else None


def _is_ata(data):
    if data == None:
        return False
    dev = data.get("device", {})
    if dev == None:
        return False
    d_type = dev.get("type", "")
    if d_type == None:
        return False
    return "ata" in str(d_type).lower() or d_type == ""


def _get_ata_attrs(data):
    if data == None:
        return None
    ata = data.get("ata_smart_attributes", {})
    if ata == None:
        return None
    return ata.get("table", [])


def _attr_value(table, attr_id):
    if table == None:
        return None
    for entry in table:
        if entry == None:
            continue
        cur = entry.get("raw", {})
        if cur == None:
            continue
        if entry.get("id") == attr_id:
            val = cur.get("value")
            if val == None:
                val = 0
            return entry
    return None


def _get_power_on_hours(data):
    if data == None:
        return None
    poh = data.get("power_on_time", {})
    if poh == None:
        return None
    return poh.get("hours")


def _get_model(data):
    if data == None:
        return ""
    model = data.get("model_name")
    if model == None:
        return ""
    return str(model)


def _get_serial(data):
    if data == None:
        return ""
    ident = data.get("serial_number")
    if ident == None:
        return ""
    return str(ident)


def _get_dev_name(dev):
    return dev


def _discover(ctx, params):
    devices = _get_devices(ctx)
    out = []
    for dev, dtype in devices.items():
        data = _get_smart_json(ctx, dev, dtype)
        if not _is_ata(data):
            continue
        table = _get_ata_attrs(data)
        if table == None or len(table) == 0:
            continue
        ata_params = {}
        for aid in [5, 10, 184, 187, 188, 196, 197, 199]:
            entry = _attr_value(table, aid)
            val = 0
            if entry != None:
                raw = entry.get("raw", {})
                if raw != None:
                    v = raw.get("value")
                    if v != None:
                        val = v
            ata_params["id_" + str(aid)] = val
        out.append({
            "item": dev,
            "params": ata_params,
            "metrics": [
                "harddrive_reallocated_sectors",
                "harddrive_spin_retries",
                "harddrive_power_cycles",
                "harddrive_end_to_end_errors",
                "harddrive_uncorrectable_errors",
                "harddrive_cmd_timeouts",
                "harddrive_reallocated_events",
                "harddrive_pending_sectors",
                "harddrive_udma_crc_errors",
                "harddrive_crc_errors",
                "uptime",
            ],
            "service_labels": {
                "cmk/smart/type": "ATA",
                "cmk/smart/device": _get_dev_name(dev),
                "cmk/smart/model": _get_model(data),
                "cmk/smart/serial": _get_serial(data),
            },
        })
    return {
        "changed": False,
        "msg": "discovered %d ATA SMART devices" % len(out),
        "data": {"discovery": out},
    }


def _check_upper_levels(value, levels_upper, warn, crit):
    if levels_upper != None and len(levels_upper) >= 2:
        warn_v = levels_upper[0]
        crit_v = levels_upper[1]
        state = "CRIT" if (crit_v != None and value >= crit_v) else ("WARN" if (warn_v != None and value >= warn_v) else "OK")
        return state
    return "OK"


def _check_single(item, value, param_tuple, discovered_value, label, metric_name, metrics, summaries):
    param_name = param_tuple[0]
    if param_name == "discovered_value" or param_name == "levels_upper":
        levels = param_tuple[1]
    else:
        levels = None
    
    if levels == None or levels == []:
        if discovered_value != None and value > discovered_value:
            state = "CRIT"
            summaries.append("%s: %s (during discovery: %s) (!!) (%s)" % (label, value, discovered_value, state))
        else:
            state = "OK"
            summaries.append("%s: %s (%s)" % (label, value, state))
    else:
        state = _check_upper_levels(value, levels, None, None)
        if state == "CRIT":
            summaries.append("%s: %s (!!) (%s)" % (label, value, state))
        elif state == "WARN":
            summaries.append("%s: %s (!) (%s)" % (label, value, state))
        else:
            summaries.append("%s: %s (%s)" % (label, value, state))
    
    if metric_name != None:
        metrics[metric_name] = value
    return state


def _check(ctx, params):
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no ATA SMART item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not _probe_smartctl(ctx):
        return {"changed": False, "msg": "smartctl not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    devices = _get_devices(ctx)
    if item not in devices:
        return {"changed": False, "msg": "device " + item + " not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    dtype = devices[item]
    data = _get_smart_json(ctx, item, dtype)
    if not _is_ata(data):
        return {"changed": False, "msg": "device " + item + " is not ATA", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    table = _get_ata_attrs(data)
    if table == None:
        return {"changed": False, "msg": "no SMART attributes for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    metrics = {}
    summaries = []
    worst_state = "OK"
    
    state_rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    
    def _max_state(s1, s2):
        if state_rank.get(s1, 0) >= state_rank.get(s2, 0):
            return s1
        return s2
    
    # id_5: Reallocated sectors
    entry = _attr_value(table, 5)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        levels_5 = params.get("levels_5", ("discovered_value", None))
        disc_5 = params.get("id_5", 0)
        s = _check_single(item, val, levels_5, disc_5, "Reallocated sectors", "harddrive_reallocated_sectors", metrics, summaries)
        worst_state = _max_state(worst_state, s)
    
    # power_on_time -> uptime metric
    poh = _get_power_on_hours(data)
    if poh != None:
        metrics["uptime"] = poh * 3600
    
    # id_10: Spin retries
    entry = _attr_value(table, 10)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        levels_10 = params.get("levels_10", ("discovered_value", None))
        disc_10 = params.get("id_10", 0)
        s = _check_single(item, val, levels_10, disc_10, "Spin retries", "harddrive_spin_retries", metrics, summaries)
        worst_state = _max_state(worst_state, s)
    
    # id_12: Power cycles
    entry = _attr_value(table, 12)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        metrics["harddrive_power_cycles"] = val
    
    # id_184: End-to-End Errors
    entry = _attr_value(table, 184)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        levels_184 = params.get("levels_184", ("discovered_value", None))
        disc_184 = params.get("id_184", 0)
        s = _check_single(item, val, levels_184, disc_184, "End-to-End Errors", "harddrive_end_to_end_errors", metrics, summaries)
        worst_state = _max_state(worst_state, s)
    
    # id_187: Uncorrectable errors
    entry = _attr_value(table, 187)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        levels_187 = params.get("levels_187", ("discovered_value", None))
        disc_187 = params.get("id_187", 0)
        s = _check_single(item, val, levels_187, disc_187, "Uncorrectable errors", "harddrive_uncorrectable_errors", metrics, summaries)
        worst_state = _max_state(worst_state, s)
    
    # id_188: Command timeout counter
    entry = _attr_value(table, 188)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        metrics["harddrive_cmd_timeouts"] = val
        if val > 0:
            worst_state = _max_state(worst_state, "CRIT")
            summaries.append("Command Timeout Counter: %s (!!) (CRIT)" % str(val))
        else:
            summaries.append("Command Timeout Counter: %s (OK)" % str(val))
    
    # id_196: Reallocated events
    entry = _attr_value(table, 196)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        levels_196 = params.get("levels_196", ("discovered_value", None))
        disc_196 = params.get("id_196", 0)
        s = _check_single(item, val, levels_196, disc_196, "Reallocated events", "harddrive_reallocated_events", metrics, summaries)
        worst_state = _max_state(worst_state, s)
    
    # id_197: Pending sectors
    entry = _attr_value(table, 197)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        levels_197 = params.get("levels_197", ("discovered_value", None))
        disc_197 = params.get("id_197", 0)
        s = _check_single(item, val, levels_197, disc_197, "Pending sectors", "harddrive_pending_sectors", metrics, summaries)
        worst_state = _max_state(worst_state, s)
    
    # id_199: CRC errors
    entry = _attr_value(table, 199)
    if entry != None:
        raw = entry.get("raw", {})
        val = 0
        if raw != None:
            v = raw.get("value")
            if v != None:
                val = v
        levels_199 = params.get("levels_199", ("discovered_value", None))
        disc_199 = params.get("id_199", 0)
        name = entry.get("name", "")
        if name == "UDMA_CRC_Error_Count":
            label = "UDMA CRC errors"
            metric_name = "harddrive_udma_crc_errors"
        else:
            label = "CRC errors"
            metric_name = "harddrive_crc_errors"
        s = _check_single(item, val, levels_199, disc_199, label, metric_name, metrics, summaries)
        worst_state = _max_state(worst_state, s)
    
    detail = "\n".join(summaries)
    if worst_state == "OK":
        msg = ", ".join(summaries)
    else:
        msg = ", ".join(summaries)
    
    return {"changed": False, "msg": msg, "data": {"state": worst_state, "metrics": metrics, "details": detail}}