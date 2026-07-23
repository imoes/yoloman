def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        section = _parse_bluenet2_powerrail_snmp(ctx, host, community)
        if section == None:
            return {"changed": False, "msg": "failed to fetch SNMP data", "data": {"discovery": []}}

        out = []
        for key in section.get("inlet", {}):
            out.append({"item": key, "params": {}, "metrics": ["current"]})
        for key in section.get("phases", {}):
            out.append({"item": key, "params": {}, "metrics": ["voltage", "current", "power", "frequency", "appower"]})
        for key in section.get("rcm_phases", {}):
            out.append({"item": key, "params": {"differential_current_ac": (3.5, 30.0), "differential_current_dc": (70.0, 100.0)}, "metrics": ["differential_current_ac", "differential_current_dc"]})

        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    section = _parse_bluenet2_powerrail_snmp(ctx, host, community)
    if section == None:
        return {"changed": False, "msg": "failed to fetch SNMP data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section_key = None
    if item.startswith("Inlet") or item.find("Neutral") != -1:
        section_key = "inlet"
    elif item.startswith("Phase"):
        section_key = "phases"
    elif item.startswith("RCM Phase"):
        section_key = "rcm_phases"
    else:
        for k in ["inlet", "phases", "rcm_phases"]:
            if item in section.get(k, {}):
                section_key = k
                break

    if section_key == None:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_phase = section.get(section_key, {}).get(item)
    if raw_phase == None:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    metrics = {}
    details_parts = []

    if section_key == "inlet":
        if "current" in raw_phase:
            reading, status_info = raw_phase["current"]
            warn = params.get("warn", 10.0) if params.get("warn") != None else 10.0
            crit = params.get("crit", 15.0) if params.get("crit") != None else 15.0
            if reading >= crit:
                state = "CRIT"
            elif reading >= warn:
                state = "WARN" if state != "CRIT" else state
            metrics["current"] = reading
            details_parts.append("Current: %s A" % str(reading))
    elif section_key == "phases":
        for m in ["voltage", "current", "power", "frequency", "appower"]:
            if m in raw_phase:
                reading, status_info = raw_phase[m]
                metrics[m] = reading
                details_parts.append("%s: %s" % (m.capitalize(), str(reading)))
                if status_info[0] >= 2:
                    state = "CRIT"
                elif status_info[0] == 1 and state != "CRIT":
                    state = "WARN"
    elif section_key == "rcm_phases":
        ac_warn = 3.5
        ac_crit = 30.0
        dc_warn = 70.0
        dc_crit = 100.0
        if "differential_current_ac" in raw_phase:
            reading, status_info = raw_phase["differential_current_ac"]
            metrics["differential_current_ac"] = reading
            details_parts.append("AC diff current: %s A" % str(reading))
            if reading >= ac_crit:
                state = "CRIT"
            elif reading >= ac_warn and state != "CRIT":
                state = "WARN"
            if status_info[0] >= 2:
                state = "CRIT"
            elif status_info[0] == 1 and state != "CRIT":
                state = "WARN"
        if "differential_current_dc" in raw_phase:
            reading, status_info = raw_phase["differential_current_dc"]
            metrics["differential_current_dc"] = reading
            details_parts.append("DC diff current: %s A" % str(reading))
            if reading >= dc_crit:
                state = "CRIT"
            elif reading >= dc_warn and state != "CRIT":
                state = "WARN"
            if status_info[0] >= 2:
                state = "CRIT"
            elif status_info[0] == 1 and state != "CRIT":
                state = "WARN"

    summary = "OK - " + ", ".join(details_parts) if details_parts else "OK"
    if state != "OK":
        summary = state + " - " + ", ".join(details_parts) if details_parts else state

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }


_STATUS_MAP = {
    "0": (0, "expected"),
    "1": (3, "undefined"),
    "2": (0, "OK"),
    "3": (2, "error high"),
    "4": (2, "error low"),
    "5": (1, "warning high"),
    "6": (1, "warning low"),
    "7": (2, "lost"),
    "8": (1, "deactivate"),
    "9": (2, "on alarm identify"),
    "10": (2, "off alarm identify"),
    "11": (2, "on alarm"),
    "12": (2, "off alarm"),
    "13": (1, "on warning identify"),
    "14": (1, "off warning identify"),
    "15": (1, "on warning"),
    "16": (1, "off warning"),
    "17": (0, "on identify"),
    "18": (0, "off identify"),
    "19": (0, "on"),
    "20": (1, "off"),
    "21": (2, "on child alarm"),
    "22": (2, "off child alarm"),
    "23": (1, "on child warning"),
    "24": (1, "off child warning"),
    "25": (2, "child alarm"),
    "26": (1, "child warning"),
    "27": (2, "lost child"),
    "36": (1, "update in progress"),
    "37": (2, "update error"),
    "38": (1, "ongoing switch"),
    "39": (2, "high"),
    "40": (1, "low"),
    "41": (2, "alarm"),
    "42": (1, "warning"),
    "43": (0, "ok"),
    "44": (1, "disabled"),
    "45": (1, "fw version too new"),
}

_PHASE_TYPE_MAP = {
    "1": ("phases", "Phase", "voltage"),
    "4": ("phases", "Phase", "current"),
    "18": ("phases", "Phase", "appower"),
    "19": ("phases", "Phase", "power"),
    "23": ("phases", "Phase", "frequency"),
    "7": ("rcm_phases", "RCM Phase", "differential_current_ac"),
    "8": ("rcm_phases", "RCM Phase", "differential_current_dc"),
    "9": ("inlet", "Neutral Current", "current"),
}

_SENSOR_TYPE_MAP = {
    "256": "temp",
    "257": "humidity",
}


def _pow10(exp):
    result = 1.0
    if exp >= 0:
        for _ in range(exp):
            result = result * 10.0
    else:
        result = 1.0
        for _ in range(-exp):
            result = result / 10.0
    return result


def _parse_bluenet2_powerrail_snmp(ctx, host, community):
    res0 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.31770.2.2.6.2.1.4"], mutates=False)
    res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.31770.2.2.6.3.1.5"], mutates=False)
    res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.31770.2.2.6.6.1.8"], mutates=False)
    res3_type = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.31770.2.2.8.2.1.6"], mutates=False)
    res3_status = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.31770.2.2.8.2.1.7"], mutates=False)
    res3_scale = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.31770.2.2.8.2.1.9"], mutates=False)
    res3_value = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.31770.2.2.8.4.1.5"], mutates=False)

    if res0.rc != 0 or res1.rc != 0 or res2.rc != 0 or res3_type.rc != 0 or res3_status.rc != 0 or res3_scale.rc != 0 or res3_value.rc != 0:
        return None

    def parse_line(line):
        parts = line.strip().split(None, 2)
        if len(parts) >= 2:
            return parts[0], parts[1] if len(parts) == 2 else " ".join(parts[1:])
        return None, None

    pre_parsed = {}
    oid_sections = [(0, "inlet"), (1, "phases"), (2, "rcm_phases"), (4, "sockets"), (5, "fuses")]

    for line in res0.stdout.splitlines():
        oid, val = parse_line(line)
        if oid == None or val == None:
            continue
        parts_oid = oid.split(".")
        if len(parts_oid) < 12:
            continue
        oid_end_str = ".".join(parts_oid[-3:])
        parts_end = oid_end_str.split(".")
        if len(parts_end) < 3:
            continue
        inlet_id = parts_end[0] + "." + parts_end[1]
        friendly_name = val.strip()
        pre_parsed.setdefault(inlet_id, {})
        for sec, name in oid_sections:
            pre_parsed[inlet_id].setdefault(name, {})
        pre_parsed[inlet_id]["inlet"].setdefault(oid_end_str, {"id": oid_end_str, "name": friendly_name})

    for line in res1.stdout.splitlines():
        oid, val = parse_line(line)
        if oid == None or val == None:
            continue
        parts_oid = oid.split(".")
        if len(parts_oid) < 12:
            continue
        oid_end_str = ".".join(parts_oid[-3:])
        parts_end = oid_end_str.split(".")
        if len(parts_end) < 3:
            continue
        inlet_id = parts_end[0] + "." + parts_end[1]
        friendly_name = val.strip()
        pre_parsed.setdefault(inlet_id, {})
        for sec, name in oid_sections:
            pre_parsed[inlet_id].setdefault(name, {})
        pre_parsed[inlet_id]["phases"].setdefault(oid_end_str, {"id": oid_end_str, "name": friendly_name})

    for line in res2.stdout.splitlines():
        oid, val = parse_line(line)
        if oid == None or val == None:
            continue
        parts_oid = oid.split(".")
        if len(parts_oid) < 12:
            continue
        oid_end_str = ".".join(parts_oid[-3:])
        parts_end = oid_end_str.split(".")
        if len(parts_end) < 3:
            continue
        inlet_id = parts_end[0] + "." + parts_end[1]
        friendly_name = val.strip()
        pre_parsed.setdefault(inlet_id, {})
        for sec, name in oid_sections:
            pre_parsed[inlet_id].setdefault(name, {})
        pre_parsed[inlet_id]["rcm_phases"].setdefault(oid_end_str, {"id": oid_end_str, "name": friendly_name})

    var_entries = []
    map_type = {}
    map_status = {}
    map_scale = {}
    map_value = {}

    for line in res3_type.stdout.splitlines():
        oid, val = parse_line(line)
        if oid != None and val != None:
            map_type[oid] = val.strip()

    for line in res3_status.stdout.splitlines():
        oid, val = parse_line(line)
        if oid != None and val != None:
            map_status[oid] = val.strip()

    for line in res3_scale.stdout.splitlines():
        oid, val = parse_line(line)
        if oid != None and val != None:
            map_scale[oid] = val.strip()

    for line in res3_value.stdout.splitlines():
        oid, val = parse_line(line)
        if oid != None and val != None:
            map_value[oid] = val.strip()

    for oid in map_type:
        ty = map_type.get(oid)
        status = map_status.get(oid)
        scale = map_scale.get(oid)
        value = map_value.get(oid)
        if ty == None or status == None or scale == None or value == None:
            continue
        var_entries.append((oid, ty, status, scale, value))

    parsed = {"sensors": {}}
    for name in ["phases", "rcm_phases", "inlet", "sockets", "fuses"]:
        parsed[name] = {}

    for oid, ty, status, scale_str, value_str in var_entries:
        if not ty.isdigit() or not status.isdigit():
            continue
        ty_int = int(ty)
        status_int = int(status)
        status_info = _STATUS_MAP.get(status, (3, "undefined"))

        if scale_str.isdigit() or (scale_str.find("-") != -1 and scale_str.replace("-", "").isdigit()):
            exponent = int(scale_str)
        else:
            exponent = 0

        reading = float(value_str) * _pow10(exponent)

        parts_oid = oid.split(".")
        if len(parts_oid) < 14:
            continue

        oid_end_str = parts_oid[-1]

        if ty_int in _PHASE_TYPE_MAP:
            phase_ty, phase_txt, what = _PHASE_TYPE_MAP[ty_int]
            inlet_id = None
            for iid in pre_parsed:
                for sec in ["phases", "rcm_phases", "inlet", "sockets", "fuses"]:
                    if oid_end_str in pre_parsed[iid].get(sec, {}):
                        inlet_id = iid
                        break
                if inlet_id != None:
                    break

            if inlet_id != None:
                parts_end = oid_end_str.split(".")
                idx = int(parts_end[-1]) + 1 if len(parts_end) > 0 and parts_end[-1].isdigit() else 1
                phase_name = "%s %s %d" % (inlet_id, phase_txt, idx)
                parsed[phase_ty].setdefault(phase_name, pre_parsed[inlet_id].get(phase_ty, {}).get(oid_end_str, {"id": oid_end_str, "name": "unknown"}))
                parsed[phase_ty][phase_name].setdefault(what, (reading, status_info))

        elif ty_int in _SENSOR_TYPE_MAP:
            pdu_info = parts_oid[-4]
            channel = parts_oid[-3]
            ext_channel = parts_oid[-2]
            sensor_name = "Sensor PDU %s %s/%s" % (pdu_info, channel, ext_channel)

            inst = parsed["sensors"].setdefault(_SENSOR_TYPE_MAP[ty_int], {})
            inst.setdefault(sensor_name, (reading, status_info))

    return parsed