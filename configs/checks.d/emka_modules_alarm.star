# Checkmk check: checkmk.emka_modules_alarm
# Translated from the Checkmk emka_modules SNMP check to a read-only Starlark
# module. This module reproduces the alarm sub-check (discover + check) by
# querying the Elmarkronic ELM2-MIB over SNMP directly with net-snmp, using the
# same OID tree the Checkmk SNMPSection fetches.

# SNMP base OIDs (from ELM2-MIB / cmk emka_modules SNMPSection)
_BASE_ALARMS = ".1.3.6.1.4.1.13595.2.2.3.1"
_BASE_MODULE_LINK = ".1.3.6.1.4.1.13595.2.1.3.3.1"

_MAP_COMPONENT_TYPES = {
    "1": "alarm",
    "2": "handle",
    "3": "sensor",
    "4": "relay",
    "5": "keypad",
    "6": "card_terminal",
    "7": "phone_modem",
    "8": "analogous_output",
}

_MAP_MODULE_TYPES = {
    "0": "vacant",
    "8": "U8, keypad",
    "9": "U9, card module (proximity)",
    "10": "U10, phone module (modem)",
    "11": "U11/U32, up to 8 handles / single point latches",
    "12": "U12/U33, up to 2 handles / single point latches",
    "13": "U13, 4 sensors and 4 relays",
    "14": "U14, communication module",
    "15": "fultifunction module M15",
    "16": "fultifunction module M16",
}

_MAP_ALARM_STATES = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("OK", "inactive"),
    "3": ("CRIT", "active"),
    "4": ("OK", "latched"),
}


def _is_emka(ctx, host, community):
    descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if descr.rc != 0:
        return False
    if descr.stdout.find("emka") == -1:
        return False
    sysid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid.rc != 0:
        return False
    return sysid.stdout.startswith(".1.3.6.1.4.1.13595")


def _walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return {}
    out = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        val = line[sp + 1:]
        idx = full_oid[len(oid) + 1:]
        out[idx] = val
    return out


def _get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _build_alarms(ctx, host, community):
    comp_tree = _walk(ctx, host, community, _BASE_MODULE_LINK)
    instances = {}
    for full_oid in comp_tree.keys():
        idx = full_oid[len(_BASE_MODULE_LINK) + 1:]
        parts = idx.split(".")
        if len(parts) < 2:
            continue
        mo_index = parts[0]
        co_index = parts[1]
        instances[idx] = {"mo_index": mo_index, "co_index": co_index}

    col3 = _walk(ctx, host, community, _BASE_MODULE_LINK + ".3")
    col4 = _walk(ctx, host, community, _BASE_MODULE_LINK + ".4")
    col5 = _walk(ctx, host, community, _BASE_MODULE_LINK + ".5")
    col7 = _walk(ctx, host, community, _BASE_MODULE_LINK + ".7")

    basic_components = {}
    for idx, info in instances.items():
        ty = col3.get(idx, "")
        mod_info = col4.get(idx, "")
        status = col5.get(idx, "")
        remark = col7.get(idx, "")
        mo_index = info["mo_index"]
        co_index = info["co_index"]
        if mo_index == "0":
            if mod_info == "":
                itemname = "Master "
            else:
                itemname = "Master " + mod_info.split(",")[0]
        else:
            itemname = "Perip " + mo_index + " " + mod_info
        if co_index == "0":
            basic_components[itemname.strip()] = {
                "type": _MAP_MODULE_TYPES.get(co_index, co_index),
                "activation": status,
                "_location_": "0." + mo_index,
            }
            continue
        table = _MAP_COMPONENT_TYPES.get(ty, ty)
        if remark == "":
            iname = idx
        else:
            iname = remark + " " + idx
        if table == "alarm":
            if iname not in basic_components:
                basic_components[iname] = {"_location_": idx}

    alarm_link = _walk(ctx, host, community, _BASE_ALARMS + ".3")
    alarm_val = _walk(ctx, host, community, _BASE_ALARMS + ".7")

    alarms = {}
    for full_oid in alarm_link.keys():
        idx = full_oid[len(_BASE_ALARMS) + 1:]
        parts = idx.split(".")
        if len(parts) < 2:
            continue
        location = ".".join(parts[-2:])
        value = alarm_val.get(idx, "")
        matched = False
        for entry, attrs in basic_components.items():
            item_location = attrs.get("_location_", "")
            if item_location != location:
                continue
            if "alarm" not in attrs:
                continue
            alarms[entry] = {"value": value, "_location_": idx}
            matched = True
            break
        if not matched:
            alarms[idx] = {"value": value, "_location_": idx}

    return alarms


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_emka(ctx, host, community):
            return {
                "changed": False,
                "msg": "host is not an Emka/ELM2 device",
                "data": {"discovery": []},
            }
        alarms = _build_alarms(ctx, host, community)
        discovery = []
        for entry, attrs in alarms.items():
            if attrs.get("value", "") != "2":
                discovery.append({
                    "item": entry,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d alarm items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _is_emka(ctx, host, community):
        return {
            "changed": False,
            "msg": "no Emka/ELM2 device found at %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    alarms = _build_alarms(ctx, host, community)
    if item not in alarms:
        return {
            "changed": False,
            "msg": "no such alarm: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    value = alarms[item].get("value", "")
    state_readable = _MAP_ALARM_STATES.get(value, ("UNKNOWN", "unknown"))
    state, readable = state_readable
    return {
        "changed": False,
        "msg": "Status: %s" % readable,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }