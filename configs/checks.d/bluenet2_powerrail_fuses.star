# Checkmk check: checkmk.bluenet2_powerrail_fuses
# Translated to a read-only Starlark check module for the yolo-man agent.
# SNMP-based check monitoring Bachmann blueNet2 powerrail fuses.

BASE_OID = ".1.3.6.1.4.1.31770.2.2"

CIRCUIT_BASE = BASE_OID + ".6.2.1"
PHASE_BASE = BASE_OID + ".6.3.1"
RCM_BASE = BASE_OID + ".6.6.1"
SOCKET_BASE = BASE_OID + ".6.5.1"
FUSE_BASE = BASE_OID + ".6.4.1"
VAR_BASE = BASE_OID + ".8"

MAP_STATUS = {
    "0": [0, "expected"],
    "1": [3, "undefined"],
    "2": [0, "OK"],
    "3": [2, "error high"],
    "4": [2, "error low"],
    "5": [1, "warning high"],
    "6": [1, "warning low"],
    "7": [2, "lost"],
    "8": [1, "deactivate"],
    "9": [2, "on alarm identidy"],
    "10": [2, "off alarm identify"],
    "11": [2, "on alarm"],
    "12": [2, "off alarm"],
    "13": [1, "on warning identify"],
    "14": [1, "off warning identify"],
    "15": [1, "on warning"],
    "16": [1, "off warning"],
    "17": [0, "on identify"],
    "18": [0, "off identify"],
    "19": [0, "on"],
    "20": [1, "off"],
    "21": [2, "on child alarm"],
    "22": [2, "off child alarm"],
    "23": [1, "on child warning"],
    "24": [1, "off child warning"],
    "25": [2, "child alarm"],
    "26": [1, "child warning"],
    "27": [2, "lost child"],
    "36": [1, "update in progress"],
    "37": [2, "update error"],
    "38": [1, "ongoing switch"],
    "39": [2, "high"],
    "40": [1, "low"],
    "41": [2, "alarm"],
    "42": [1, "warning"],
    "43": [0, "ok"],
    "44": [1, "disabled"],
    "45": [1, "fw version too new"],
}

MAP_PHASE_TYPES = {
    "1": ["phases", "Phase", "voltage"],
    "4": ["phases", "Phase", "current"],
    "18": ["phases", "Phase", "appower"],
    "19": ["phases", "Phase", "power"],
    "23": ["phases", "Phase", "frequency"],
    "7": ["rcm_phases", "RCM Phase", "differential_current_ac"],
    "8": ["rcm_phases", "RCM Phase", "differential_current_dc"],
    "9": ["inlet", "Neutral Current", "current"],
}

MAP_SENSOR_TYPES = {
    "256": "temp",
    "257": "humidity",
}


def _pow10(e):
    if e < 0:
        result = 1.0
        for _ in range(-e):
            result = result / 10.0
        return result
    result = 1
    for _ in range(e):
        result = result * 10
    return result


def _snmp_get(ctx, host, community, oid):
    return ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, oid,
    ], mutates=False)


def _snmp_walk(ctx, host, community, oid):
    return ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid,
    ], mutates=False)


def _pdu_name(pdu_info):
    if pdu_info == "0":
        return "Master"
    return "PDU %s" % pdu_info


def _get_item_name(descr, index_str):
    return "%s %d" % (descr, int(index_str) + 1)


def _walk_to_entries(ctx, host, community, base_oid):
    res = _snmp_walk(ctx, host, community, base_oid)
    if res.rc != 0:
        return []
    entries = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].strip()
        entries.append([oid, value])
    return entries


def _build_inlet_map(ctx, host, community, base, col_rel):
    col_full = base + "." + col_rel
    entries = _walk_to_entries(ctx, host, community, col_full)
    info = {}
    for row in entries:
        oid = row[0]
        val = row[1]
        index_str = oid[len(col_full) + 1:]
        if not index_str:
            continue
        inlet_id_parts = index_str.split(".")
        inlet_id = ".".join(inlet_id_parts[:2])
        if not info.get(inlet_id):
            info[inlet_id] = {}
        identifier_bytes = index_str.split(".")
        identifier = ".".join(identifier_bytes[:-1])
        info[inlet_id][identifier] = {
            "id": val,
            "name": val,
            "friendly_name": val,
        }
    return info


def _parse_powerrail(ctx, host, community):
    pre_parsed = {}
    pre_parsed["inlet"] = _build_inlet_map(ctx, host, community, CIRCUIT_BASE, "3")
    pre_parsed["phases"] = _build_inlet_map(ctx, host, community, PHASE_BASE, "4")
    pre_parsed["rcm_phases"] = _build_inlet_map(ctx, host, community, RCM_BASE, "7")
    pre_parsed["sockets"] = _build_inlet_map(ctx, host, community, SOCKET_BASE, "6")
    pre_parsed["fuses"] = _build_inlet_map(ctx, host, community, FUSE_BASE, "5")

    var_lines = []
    for row in [["type", "2.1.6"], ["status", "2.1.7"], ["scaling", "2.1.9"], ["data", "4.1.5"]]:
        col_name = row[0]
        rel = row[1]
        col_full = VAR_BASE + "." + rel
        entries = _walk_to_entries(ctx, host, community, col_full)
        for ent in entries:
            oid = ent[0]
            val = ent[1]
            var_lines.append([col_name, oid, val, col_full])

    parsed = {
        "inlet": {},
        "phases": {},
        "rcm_phases": {},
        "sockets": {},
        "fuses": {},
        "sensors": {"temp": {}, "humidity": {}},
    }

    var_by_id = {}
    for row in var_lines:
        col_name = row[0]
        oid = row[1]
        val = row[2]
        oid_info = oid.split(".")
        identifier = ".".join(oid_info[:-1])
        if not var_by_id.get(identifier):
            var_by_id[identifier] = {}
        var_by_id[identifier][col_name] = val

    for identifier in var_by_id:
        cols = var_by_id[identifier]
        ty = cols.get("type")
        status_val = cols.get("status")
        scaling_val = cols.get("scaling")
        data_val = cols.get("data")
        if ty == None or status_val == None or scaling_val == None or data_val == None:
            continue

        oid_info = identifier.split(".")
        status_info = MAP_STATUS.get(status_val, [3, "unknown"])
        exponent = 0
        sv = scaling_val
        if sv.lstrip("-").isdigit():
            exponent = int(sv)
        reading = float(data_val) * _pow10(exponent)

        if ty in MAP_PHASE_TYPES:
            phase_ty = MAP_PHASE_TYPES[ty][0]
            phase_txt = MAP_PHASE_TYPES[ty][1]
            what = MAP_PHASE_TYPES[ty][2]
            col_idx = oid_info[-1]
            for inlet_id in pre_parsed.get(phase_ty, {}):
                inlet_info = pre_parsed[phase_ty][inlet_id]
                if identifier in inlet_info:
                    phase_name = _get_item_name("%s %s" % (inlet_id, phase_txt), col_idx)
                    if not parsed[phase_ty].get(phase_name):
                        parsed[phase_ty][phase_name] = dict(inlet_info[identifier])
                    parsed[phase_ty][phase_name][what] = [reading, status_info]
                sockets_for_inlet = pre_parsed.get("sockets", {}).get(inlet_id, {})
                if identifier in sockets_for_inlet:
                    socket_name = "%s %s" % (inlet_id, sockets_for_inlet[identifier]["id"])
                    if not parsed["sockets"].get(socket_name):
                        parsed["sockets"][socket_name] = dict(sockets_for_inlet[identifier])
                    parsed["sockets"][socket_name][what] = [reading, status_info]
                fuses_for_inlet = pre_parsed.get("fuses", {}).get(inlet_id, {})
                if identifier in fuses_for_inlet:
                    phase_id = oid_info[3]
                    fuse_name = "%s.%s %s" % (inlet_id, phase_id, fuses_for_inlet[identifier]["id"])
                    if not parsed["fuses"].get(fuse_name):
                        parsed["fuses"][fuse_name] = dict(fuses_for_inlet[identifier])
                    parsed["fuses"][fuse_name][what] = [reading, status_info]

        elif ty in MAP_SENSOR_TYPES:
            sensor_kind = MAP_SENSOR_TYPES[ty]
            sensor_oid_parts = identifier.split(".")
            pdu_num = sensor_oid_parts[0]
            sensor_type = sensor_oid_parts[3]
            channel_ext = sensor_oid_parts[4]
            sensor_name = "Sensor %s %s/%s" % (_pdu_name(pdu_num), sensor_type, channel_ext)
            inst = parsed["sensors"].get(sensor_kind)
            if inst == None:
                inst = {}
                parsed["sensors"][sensor_kind] = inst
            if inst.get(sensor_name) == None:
                inst[sensor_name] = [reading, status_info]

    return parsed


def _grade_value(val, warn, crit):
    if val >= crit:
        return "CRIT"
    if val >= warn:
        return "WARN"
    return "OK"


def _check_fuse(fuse_data, params):
    warn_current = params.get("warn_current", 16.0)
    crit_current = params.get("crit_current", 20.0)
    warn_power = params.get("warn_power", 3680.0)
    crit_power = params.get("crit_power", 4600.0)
    warn_appower = params.get("warn_appower", 3680.0)
    crit_appower = params.get("crit_appower", 4600.0)
    warn_voltage = params.get("warn_voltage", 230.0)
    crit_voltage = params.get("crit_voltage", 240.0)
    warn_frequency = params.get("warn_frequency", 50.0)
    crit_frequency = params.get("crit_frequency", 50.0)

    state = "OK"
    messages = []
    metrics = {}

    if "current" in fuse_data:
        val_status = fuse_data["current"]
        val = val_status[0]
        status = val_status[1]
        s = _grade_value(val, warn_current, crit_current)
        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN":
            if state != "CRIT":
                state = "WARN"
        metrics["current"] = val
        messages.append("Current: %f A (%s)" % (val, status[1]))

    if "power" in fuse_data:
        val_status = fuse_data["power"]
        val = val_status[0]
        status = val_status[1]
        s = _grade_value(val, warn_power, crit_power)
        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN":
            if state != "CRIT":
                state = "WARN"
        metrics["power"] = val
        messages.append("Power: %f W (%s)" % (val, status[1]))

    if "appower" in fuse_data:
        val_status = fuse_data["appower"]
        val = val_status[0]
        status = val_status[1]
        s = _grade_value(val, warn_appower, crit_appower)
        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN":
            if state != "CRIT":
                state = "WARN"
        metrics["appower"] = val
        messages.append("Apparent Power: %f VA (%s)" % (val, status[1]))

    if "voltage" in fuse_data:
        val_status = fuse_data["voltage"]
        val = val_status[0]
        status = val_status[1]
        s = _grade_value(val, warn_voltage, crit_voltage)
        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN":
            if state != "CRIT":
                state = "WARN"
        metrics["voltage"] = val
        messages.append("Voltage: %f V (%s)" % (val, status[1]))

    if "frequency" in fuse_data:
        val_status = fuse_data["frequency"]
        val = val_status[0]
        status = val_status[1]
        s = _grade_value(val, warn_frequency, crit_frequency)
        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN":
            if state != "CRIT":
                state = "WARN"
        metrics["frequency"] = val
        messages.append("Frequency: %f Hz (%s)" % (val, status[1]))

    if len(metrics) == 0:
        return {"state": "UNKNOWN", "metrics": {}, "details": "no data for this fuse", "msg": "no data for fuse"}

    msg = "; ".join(messages)
    return {"state": state, "metrics": metrics, "details": msg, "msg": msg}


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_oid_res = _snmp_get(ctx, host, community, "1.3.6.1.2.1.1.2.0")
    if sys_oid_res.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "snmp not available", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "snmp not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sys_oid_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "snmp sysOID probe failed", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "snmp sysOID probe failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if "31770.2.1" not in sys_oid_res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "not a Bachmann blueNet2 device", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "not a Bachmann blueNet2 device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        fuse_entries = _walk_to_entries(ctx, host, community, FUSE_BASE + ".5")
        discovery = []
        seen = []
        for row in fuse_entries:
            oid = row[0]
            val = row[1]
            col_full = FUSE_BASE + ".5"
            index_str = oid[len(col_full) + 1:]
            if not index_str:
                continue
            oid_info = oid.split(".")
            inlet_id_parts = index_str.split(".")
            inlet_id = ".".join(inlet_id_parts[:2])
            phase_id = "0"
            if len(inlet_id_parts) > 3:
                phase_id = inlet_id_parts[3]
            fuse_name = "%s.%s %s" % (inlet_id, phase_id, val)
            if fuse_name in seen:
                continue
            seen.append(fuse_name)
            discovery.append({
                "item": fuse_name,
                "params": {
                    "warn_current": 16.0,
                    "crit_current": 20.0,
                    "warn_power": 3680.0,
                    "crit_power": 4600.0,
                    "warn_appower": 3680.0,
                    "crit_appower": 4600.0,
                    "warn_voltage": 230.0,
                    "crit_voltage": 240.0,
                    "warn_frequency": 50.0,
                    "crit_frequency": 50.0,
                },
                "metrics": ["current", "power", "appower", "voltage", "frequency"],
            })
        return {
            "changed": False,
            "msg": "discovered %d fuses" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")
    parsed = _parse_powerrail(ctx, host, community)

    fuses = parsed.get("fuses", {})
    fuse_data = fuses.get(item)
    if fuse_data == None:
        return {
            "changed": False,
            "msg": "no such fuse: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    result = _check_fuse(fuse_data, params)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {"state": result["state"], "metrics": result["metrics"], "details": result["details"]},
    }