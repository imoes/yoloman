# lg_pdu_aux starlark check module
# Translated from Checkmk plugin cmk.plugins.lgp.lgp_pdu_aux

_LGP_PDU_AUX_TYPES = {
    "0": "UNSPEC",
    "1": "TEMP",
    "2": "HUM",
    "3": "DOOR",
    "4": "CONTACT",
}

_LGP_PDU_AUX_STATES = [
    "not-specified",
    "open",
    "closed",
]

def _savefloat(s):
    if not s or s == "":
        return 0.0
    # Check if string contains only digits (possibly with leading minus)
    stripped = s.lstrip("-")
    if stripped.isdigit():
        return float(s) * 0.1
    else:
        return 0.0

def _saveint(s):
    if not s or s == "":
        return 0
    stripped = s.lstrip("-")
    if stripped.isdigit():
        return int(s)
    else:
        return 0

def _parse_lgp_pdu_aux(output_lines):
    section = {}
    for line in output_lines:
        if not line.strip():
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        # oid is like "10.1.1.1", "15.1.2.1", etc.
        dot_idx = oid.find(".")
        if dot_idx == -1:
            continue
        type_idx = oid[:dot_idx]
        id_part = oid[dot_idx+1:]  # e.g., "1.1.1", "1.2.1"
        if not section.has_key(id_part):
            # Extract the last part as TypeIndex
            parts_id = id_part.split(".")
            type_index = parts_id[-1] if parts_id else ""
            section[id_part] = {"TypeIndex": type_index}

        converter = None
        key = ""
        if type_idx == "10":
            converter = lambda x: _LGP_PDU_AUX_TYPES.get(x, "UNHANDLED")
            key = "Type"
        elif type_idx == "15":
            converter = str
            key = "SystemLabel"
        elif type_idx == "20":
            converter = str
            key = "UserLabel"
        elif type_idx == "35":
            converter = str
            key = "SerialNumber"
        elif type_idx == "70":
            converter = _savefloat
            key = "Temp"
        elif type_idx == "75":
            converter = _savefloat
            key = "TempLowCrit"
        elif type_idx == "80":
            converter = _savefloat
            key = "TempHighCrit"
        elif type_idx == "85":
            converter = _savefloat
            key = "TempLowWarn"
        elif type_idx == "90":
            converter = _savefloat
            key = "TempHighWarn"
        elif type_idx == "95":
            converter = _savefloat
            key = "Hum"
        elif type_idx == "100":
            converter = _savefloat
            key = "HumLowCrit"
        elif type_idx == "105":
            converter = _savefloat
            key = "HumHighCrit"
        elif type_idx == "110":
            converter = _savefloat
            key = "HumLowWarn"
        elif type_idx == "115":
            converter = _savefloat
            key = "HumHighWarn"
        elif type_idx == "120":
            converter = _saveint
            key = "DoorState"
        elif type_idx == "125":
            converter = _saveint
            key = "DoorConfig"

        if converter != None:
            section[id_part][key] = converter(value)

    return section

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", params.get("host", "localhost"), ".1.3.6.1.4.1.476.1.42.3.8.60.15"], mutates=False)
        lines = res.stdout.splitlines()
        section = _parse_lgp_pdu_aux(lines)
        items = []
        for pdu in section.values():
            if "Type" in pdu and "SystemLabel" in pdu and "TypeIndex" in pdu:
                item_name = "%s-%s-%s" % (pdu["Type"], pdu["SystemLabel"], pdu["TypeIndex"])
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["temp", "hum"]
                })
        return {"changed": False, "msg": "discovered %d AUX sensors" % len(items), "data": {"discovery": items}}

    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", params.get("host", "localhost"), ".1.3.6.1.4.1.476.1.42.3.8.60.15"], mutates=False)
    lines = res.stdout.splitlines()
    section = _parse_lgp_pdu_aux(lines)

    pdu_found = None
    for pdu in section.values():
        if "Type" not in pdu or "SystemLabel" not in pdu or "TypeIndex" not in pdu:
            continue
        expected = "%s-%s-%s" % (pdu["Type"], pdu["SystemLabel"], pdu["TypeIndex"])
        if expected == item:
            pdu_found = pdu
            break

    if pdu_found == None:
        return {"changed": False, "msg": "Could not find given PDU.", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build message and state
    summary_parts = []
    if pdu_found.get("UserLabel", "") != "":
        summary_parts.append("Label: %s (%s)" % (pdu_found["UserLabel"], pdu_found["SystemLabel"]))
    else:
        summary_parts.append("Label: %s" % pdu_found["SystemLabel"])

    state = "OK"
    metrics = {}

    pdu_type = pdu_found.get("Type", "")
    if pdu_type == "TEMP":
        temp = float(pdu_found.get("Temp", 0))
        temp_high_warn = float(pdu_found.get("TempHighWarn", 0))
        temp_high_crit = float(pdu_found.get("TempHighCrit", 0))
        temp_low_warn = float(pdu_found.get("TempLowWarn", 0))
        temp_low_crit = float(pdu_found.get("TempLowCrit", 0))

        if temp >= temp_high_crit or temp <= temp_low_crit:
            state = "CRIT"
        elif temp >= temp_high_warn or temp <= temp_low_warn:
            state = "WARN"

        summary_parts.append("Temperature: %fC" % temp)
        metrics["temp"] = temp

    elif pdu_type == "HUM":
        hum = float(pdu_found.get("Hum", 0))
        hum_high_warn = float(pdu_found.get("HumHighWarn", 0))
        hum_high_crit = float(pdu_found.get("HumHighCrit", 0))
        hum_low_warn = float(pdu_found.get("HumLowWarn", 0))
        hum_low_crit = float(pdu_found.get("HumLowCrit", 0))

        if hum >= hum_high_crit or hum <= hum_low_crit:
            state = "CRIT"
        elif hum >= hum_high_warn or hum <= hum_low_warn:
            state = "WARN"

        summary_parts.append("Humidity: %f%%" % hum)
        metrics["hum"] = hum

    elif pdu_type == "DOOR":
        door_state_val = pdu_found.get("DoorState", "0")
        if door_state_val.isdigit():
            door_state_idx = int(door_state_val)
            door_state = _LGP_PDU_AUX_STATES[door_state_idx] if door_state_idx < len(_LGP_PDU_AUX_STATES) else "unknown"
        else:
            door_state = "unknown"

        door_config_val = pdu_found.get("DoorConfig", "0")
        if door_config_val.isdigit():
            door_config = int(door_config_val)
        else:
            door_config = 0

        if door_config == 1 and door_state == "open":
            state = "CRIT"
            summary_parts.append("Door is %s (!!)" % door_state)
        else:
            summary_parts.append("Door is %s" % door_state)

    summary = ", ".join(summary_parts)
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": metrics, "details": ""}}