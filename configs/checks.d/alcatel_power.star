OPERSTATE_MAP = {
    "1": "up",
    "2": "down",
    "3": "testing",
    "4": "unknown",
    "5": "secondary",
    "6": "not present",
    "7": "unpowered",
    "9": "master",
}

NO_POWER_SUPPLY = "no power supply"

TYPE_MAP = {
    "0": NO_POWER_SUPPLY,
    "1": "AC",
    "2": "DC",
}

BASE_OID = ".1.3.6.1.4.1.6486.800.1.1.1.1.1.1.1"

def _parse_walk(output, prefix):
    result = {}
    for line in output.splitlines():
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val_part = parts[1].strip()
        if ": " in val_part:
            val = val_part.split(": ", 1)[1].strip()
        else:
            val = val_part
        if oid.startswith(prefix):
            idx = oid[len(prefix):]
            result[idx] = val
    return result

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    status_oid = BASE_OID + ".2"
    type_oid = BASE_OID + ".36"

    res_status = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, status_oid],
        mutates=False,
    )
    res_type = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, type_oid],
        mutates=False,
    )

    if res_status.rc != 0 or res_type.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_by_idx = _parse_walk(res_status.stdout, status_oid + ".")
    type_by_idx = _parse_walk(res_type.stdout, type_oid + ".")

    all_idx = set(list(status_by_idx.keys()) + list(type_by_idx.keys()))

    section = {}
    for idx in all_idx:
        raw_status = status_by_idx.get(idx, "4").strip().strip('"')
        raw_type = type_by_idx.get(idx, "0").strip().strip('"')
        oper_state = OPERSTATE_MAP.get(raw_status, "unknown[%s]" % raw_status)
        power_type = TYPE_MAP.get(raw_type, NO_POWER_SUPPLY)
        section[idx] = {"oper_state": oper_state, "power_type": power_type}

    if params.get("_discover"):
        discovered = []
        for idx, dev in section.items():
            if dev["power_type"] != NO_POWER_SUPPLY and dev["oper_state"] != "not present":
                discovered.append({"item": idx, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    dev = section.get(item)

    if dev == None:
        return {
            "changed": False,
            "msg": "power supply not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK" if dev["oper_state"] == "up" else "CRIT"
    msg = "[%s] Operational status: %s" % (dev["power_type"], dev["oper_state"])

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }