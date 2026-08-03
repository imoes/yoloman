# Starlark translation of Checkmk check cmk.plugins/lgp.agent_based.lgp_pdu_aux
# Monitors Liebert PDU AUX sensors (temp/humidity/door) via SNMP.
# READ-ONLY: never mutates=True, never ctx.file_write.

_LGP_PDU_AUX_TYPES = {
    "0": "UNSPEC",
    "1": "TEMP",
    "2": "HUM",
    "3": "DOOR",
    "4": "CONTACT",
}

_LGP_PDU_AUX_STATES = ["not-specified", "open", "closed"]

# (type_index, converter_name, field_name). converter_name maps to a helper.
_FIELDS = [
    ("10", "type", "Type"),
    ("15", "str", "SystemLabel"),
    ("20", "str", "UserLabel"),
    ("35", "str", "SerialNumber"),
    ("70", "tenth", "Temp"),
    ("75", "tenth", "TempLowCrit"),
    ("80", "tenth", "TempHighCrit"),
    ("85", "tenth", "TempLowWarn"),
    ("90", "tenth", "TempHighWarn"),
    ("95", "tenth", "Hum"),
    ("100", "tenth", "HumLowCrit"),
    ("105", "tenth", "HumHighCrit"),
    ("110", "tenth", "HumLowWarn"),
    ("115", "tenth", "HumHighWarn"),
    ("120", "int", "DoorState"),
    ("125", "int", "DoorConfig"),
]

_BASE_OID = ".1.3.6.1.4.1.476.1.42.3.8.60.15"
_SYS_OID = ".1.3.6.1.2.1.1.2.0"
_LGP_SYS_VALUE = ".1.3.6.1.4.1.476.1.42"


def _to_float(s):
    if s == None or s == "":
        return None
    neg = s.startswith("-")
    digits = s[1:] if neg else s
    if digits == "" or not digits.replace(".", "").isdigit():
        return None
    parts = digits.split(".")
    if len(parts) > 2:
        return None
    for p in parts:
        if p == "":
            return None
    val = 0.0
    sign = -1.0 if neg else 1.0
    if "." in digits:
        int_part = parts[0]
        frac_part = parts[1]
        if int_part != "0" and not int_part.isdigit():
            return None
        iv = 0
        for c in int_part:
            iv = iv * 10 + (ord(c) - 48)
        frac = 0.0
        mult = 0.1
        for c in frac_part:
            frac = frac + (ord(c) - 48) * mult
            mult = mult * 0.1
        val = sign * (float(iv) + frac)
    else:
        iv = 0
        for c in digits:
            iv = iv * 10 + (ord(c) - 48)
        val = sign * float(iv)
    return val


def _to_int(s):
    if s == None or s == "":
        return None
    neg = s.startswith("-")
    digits = s[1:] if neg else s
    if digits == "" or not digits.isdigit():
        return None
    iv = 0
    for c in digits:
        iv = iv * 10 + (ord(c) - 48)
    return -iv if neg else iv


def _convert(value, converter_name):
    if converter_name == "type":
        return _LGP_PDU_AUX_TYPES.get(value, "UNHANDLED")
    if converter_name == "str":
        return value
    if converter_name == "tenth":
        f = _to_float(value)
        if f == None:
            return None
        return f * 0.1
    if converter_name == "int":
        return _to_int(value)
    return None


def _walk_table(ctx, host, community, oid_base):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-OQ", host, oid_base], mutates=False)
    rows = []
    if res.rc != 0 and res.rc != 1:
        return rows, res
    for line in res.stdout.splitlines():
        space_idx = line.find(" ")
        if space_idx == -1:
            continue
        line_oid = line[:space_idx]
        line_val = line[space_idx + 1:]
        rows.append((line_oid, line_val))
    return rows, res


def _sys_oid_present(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", "-OQ", host, _SYS_OID], mutates=False)
    if res.rc != 0:
        return False
    if res.stdout.strip() == _LGP_SYS_VALUE:
        return True
    return False


def _parse_section(rows):
    new_info = {}
    for oid, value in rows:
        dot = oid.find(".")
        if dot == -1:
            continue
        type_ = oid[:dot]
        id_ = oid[dot + 1:]
        if id_ not in new_info:
            type_index = id_.split(".")[-1]
            new_info[id_] = {"TypeIndex": type_index}
        for type_index, converter_name, field_name in _FIELDS:
            if type_ == type_index:
                converted = _convert(value, converter_name)
                new_info[id_][field_name] = converted
                break
    return new_info


def _item_name(pdu):
    ptype = pdu.get("Type", "")
    sys_label = pdu.get("SystemLabel", "")
    type_index = pdu.get("TypeIndex", "")
    return "%s-%s-%s" % (ptype, sys_label, type_index)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _sys_oid_present(ctx, host, community):
        if params.get("_discover"):
            return {"changed": False, "msg": "no Liebert PDU found on host",
                    "data": {"discovery": []}}
        item = params.get("item", "")
        return {"changed": False, "msg": "no Liebert PDU found on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows, walk_res = _walk_table(ctx, host, community, _BASE_OID + ".1")
    if walk_res.rc != 0 and walk_res.rc != 1 and len(rows) == 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "SNMP walk failed for Liebert PDU AUX table",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "SNMP walk failed for Liebert PDU AUX table",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_section(rows)

    if params.get("_discover"):
        discovery = []
        for pdu in section.values():
            discovery.append({
                "item": _item_name(pdu),
                "params": {},
                "metrics": ["temp", "hum", "door"],
            })
        return {"changed": False,
                "msg": "discovered %d Liebert PDU AUX sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    matched = None
    for pdu in section.values():
        if _item_name(pdu) == item:
            matched = pdu
            break

    if matched == None:
        return {"changed": False,
                "msg": "Could not find given PDU.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details = ""
    msg_parts = []

    user_label = matched.get("UserLabel", "")
    sys_label = matched.get("SystemLabel", "")
    if user_label != "" and user_label != None:
        msg_parts.append("Label: %s (%s)" % (user_label, sys_label))
    else:
        msg_parts.append("Label: %s" % sys_label)

    ptype = matched.get("Type", "")

    if ptype == "TEMP":
        temp = matched.get("Temp", None)
        if temp == None:
            return {"changed": False,
                    "msg": "no temperature value available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        metrics["temp"] = temp
        details = "Temperature: %fC" % temp
        warn_high = matched.get("TempHighWarn", None)
        crit_high = matched.get("TempHighCrit", None)
        warn_low = matched.get("TempLowWarn", None)
        crit_low = matched.get("TempLowCrit", None)
        state = "OK"
        if crit_low != None and temp <= crit_low:
            state = "CRIT"
        elif crit_high != None and temp >= crit_high:
            state = "CRIT"
        elif warn_low != None and temp <= warn_low:
            state = "WARN"
        elif warn_high != None and temp >= warn_high:
            state = "WARN"
        msg_parts.append(details)
        return {"changed": False, "msg": " ".join(msg_parts),
                "data": {"state": state, "metrics": metrics, "details": details}}

    if ptype == "HUM":
        hum = matched.get("Hum", None)
        if hum == None:
            return {"changed": False,
                    "msg": "no humidity value available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        metrics["hum"] = hum
        details = "Humidity: %f%%" % hum
        warn_high = matched.get("HumHighWarn", None)
        crit_high = matched.get("HumHighCrit", None)
        warn_low = matched.get("HumLowWarn", None)
        crit_low = matched.get("HumLowCrit", None)
        state = "OK"
        if crit_low != None and hum <= crit_low:
            state = "CRIT"
        elif crit_high != None and hum >= crit_high:
            state = "CRIT"
        elif warn_low != None and hum <= warn_low:
            state = "WARN"
        elif warn_high != None and hum >= warn_high:
            state = "WARN"
        msg_parts.append(details)
        return {"changed": False, "msg": " ".join(msg_parts),
                "data": {"state": state, "metrics": metrics, "details": details}}

    if ptype == "DOOR":
        door_state_idx = matched.get("DoorState", None)
        door_config = matched.get("DoorConfig", None)
        if door_state_idx == None:
            return {"changed": False,
                    "msg": "no door state value available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if door_state_idx < 0 or door_state_idx >= len(_LGP_PDU_AUX_STATES):
            state_str = "not-specified"
        else:
            state_str = _LGP_PDU_AUX_STATES[door_state_idx]
        state = "OK"
        if door_config == 1 and state_str == "open":
            state = "CRIT"
        details = "Door is %s" % state_str
        if state == "CRIT":
            details = details + " (!!)"
        msg_parts.append(details)
        return {"changed": False, "msg": " ".join(msg_parts),
                "data": {"state": state, "metrics": metrics, "details": details}}

    # UNSPEC / CONTACT / UNHANDLED: report OK with label
    return {"changed": False, "msg": " ".join(msg_parts),
            "data": {"state": "OK", "metrics": metrics, "details": details}}