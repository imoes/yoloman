MAP_OPER_STATE = {
    "0": "unknown",
    "1": "enabled",
    "2": "disabled",
    "3": "no license",
    "4": "enabled WN license",
    "5": "power down",
}

MAP_AVAILABILITY = {
    "1": "power off",
    "2": "offline",
    "3": "online",
    "4": "failed",
    "5": "in test",
    "6": "not installed",
}

STATE_RANK = {"OK": 0, "UNKNOWN": 1, "WARN": 2, "CRIT": 3}

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, oid],
        mutates=False,
        ok_codes=[0, 1],
    )
    rows = {}
    for line in res.stdout.splitlines():
        eq = line.find(" = ")
        if eq < 0:
            continue
        full_oid = line[:eq].strip()
        val_part = line[eq + 3:].strip()
        idx = full_oid.rsplit(".", 1)[-1]
        colon = val_part.find(": ")
        if colon >= 0:
            type_name = val_part[:colon]
            raw_val = val_part[colon + 2:].strip()
            if type_name == "Timeticks":
                paren_end = raw_val.find(")")
                if raw_val.startswith("(") and (paren_end >= 0):
                    val = raw_val[1:paren_end]
                else:
                    val = raw_val
            elif type_name == "INTEGER":
                paren = raw_val.find("(")
                if paren >= 0:
                    paren_end = raw_val.find(")", paren)
                    val = raw_val[paren + 1:paren_end] if paren_end >= 0 else raw_val
                else:
                    val = raw_val
            elif (type_name == "STRING") or (type_name == "OCTET STRING"):
                val = raw_val.strip('"')
            else:
                val = raw_val.strip('"')
        else:
            val = val_part.strip().strip('"')
        rows[idx] = val
    return rows

def _worst_state(s1, s2):
    r1 = STATE_RANK.get(s1, 0)
    r2 = STATE_RANK.get(s2, 0)
    return s1 if r1 >= r2 else s2

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_ap = ".1.3.6.1.4.1.15983.1.1.4.2.1.1"
    base_cl = ".1.3.6.1.4.1.15983.1.1.3.1.7.1"

    if params.get("_discover"):
        id_map = _snmp_walk(ctx, host, community, base_ap + ".4")
        avail_map = _snmp_walk(ctx, host, community, base_ap + ".27")
        discovery = []
        for idx in id_map:
            ap_id = id_map[idx]
            avail_code = avail_map.get(idx, "6")
            avail = MAP_AVAILABILITY.get(avail_code, "not installed")
            if avail != "not installed":
                discovery.append({
                    "item": ap_id,
                    "params": {},
                    "metrics": ["5ghz_clients", "24ghz_clients", "uptime"],
                })
        return {
            "changed": False,
            "msg": "discovered %d APs" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    descr_map = _snmp_walk(ctx, host, community, base_ap + ".2")
    id_map = _snmp_walk(ctx, host, community, base_ap + ".4")
    loc_map = _snmp_walk(ctx, host, community, base_ap + ".8")
    uptime_map = _snmp_walk(ctx, host, community, base_ap + ".17")
    oper_map = _snmp_walk(ctx, host, community, base_ap + ".26")
    avail_map = _snmp_walk(ctx, host, community, base_ap + ".27")

    row_idx = None
    for idx in id_map:
        if id_map[idx] == item:
            row_idx = idx
            break

    if row_idx == None:
        return {
            "changed": False,
            "msg": "AP not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    descr = descr_map.get(row_idx, "")
    location = loc_map.get(row_idx, "")
    uptime_str = uptime_map.get(row_idx, "")
    oper_code = oper_map.get(row_idx, "0")
    avail_code = avail_map.get(row_idx, "2")

    oper_state = MAP_OPER_STATE.get(oper_code, "unknown")
    avail_state = MAP_AVAILABILITY.get(avail_code, "offline")
    uptime = int(uptime_str) if uptime_str.isdigit() else 0

    band_map = _snmp_walk(ctx, host, community, base_cl + ".5")
    apid_map = _snmp_walk(ctx, host, community, base_cl + ".9")

    clients_24 = 0
    clients_5 = 0
    for cidx in apid_map:
        if apid_map[cidx] == item:
            band = band_map.get(cidx, "")
            if band == "1":
                clients_24 += 1
            elif band == "2":
                clients_5 += 1

    if oper_state == "unknown":
        oper_check = "UNKNOWN"
    elif oper_state in ["disabled", "no license", "power down"]:
        oper_check = "WARN"
    else:
        oper_check = "OK"

    if avail_state == "failed":
        avail_check = "CRIT"
    elif avail_state in ["power off", "offline", "in test", "not installed"]:
        avail_check = "WARN"
    else:
        avail_check = "OK"

    final_state = _worst_state(oper_check, avail_check)

    parts = [
        "[%s] Operational: %s" % (descr, oper_state),
        "Availability: %s" % avail_state,
        "Connected clients (2,4 ghz/5 ghz): %d/%d" % (clients_24, clients_5),
    ]
    if uptime > 0:
        parts.append("Uptime: %d s" % uptime)
    if location:
        parts.append("Located at %s" % location)

    metrics = {
        "5ghz_clients": clients_5,
        "24ghz_clients": clients_24,
    }
    if uptime > 0:
        metrics["uptime"] = uptime

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": final_state,
            "metrics": metrics,
            "details": "",
        },
    }