# Translation of Checkmk check: cmk/plugins/oracle/agent_based/oracle_diva_csm.py
# Monitors Oracle DIVA CSM (Celerity Storage Manager) via SNMP.

def _snmp_get(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc == 0 and res.stdout.strip() != "":
        return res.stdout.strip()
    return None

def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            rows.append((parts[0], parts[1]))
    return rows

def _status_result(reading):
    # 0 OK / 1 WARN / 2 CRIT / 3 UNKNOWN
    if reading == "1":
        return 0, "online"
    if reading == "2":
        return 2, "offline"
    if reading == "3":
        return 1, "unknown"
    return 3, "unexpected state"

def _item_name(name, element_id):
    full = name + " " + element_id
    return full.strip()

def _gather_section(ctx, community, host):
    # Mirrors the SNMPSection fetch: 6 sublists in order.
    section = []
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.2.1.1.1.2"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.2.2.1.1.3"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.2.2.1.1.8"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.3.1.1.2"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.4.1"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.4.2"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.4.4"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.4.5"))
    section.append(_snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.4.3"))
    return section

def _discover_status(ctx, community, host):
    # Library status: base .1.3.6.1.4.1.110901.1.2.1.1.1, oids ["1","2"]
    # column 1 = element_id, column 2 = reading -> single row expected
    rows = _snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.2.1.1.1.2")
    discovered = []
    for oid, val in rows:
        # index = suffix after base column
        base_oid = ".1.3.6.1.4.1.110901.1.2.1.1.1.2"
        idx = oid[len(base_oid) + 1:]
        # element_id from sibling column
        elem_oid = ".1.3.6.1.4.1.110901.1.2.1.1.1.1" + "." + idx
        elem = _snmp_get(ctx, community, host, elem_oid)
        element_id = elem if elem != None else idx
        item = _item_name("Library", element_id)
        discovered.append({
            "item": item,
            "params": {},
            "metrics": ["state"],
        })
    return discovered

def _check_status(ctx, community, host, item):
    rows = _snmp_walk(ctx, community, host, ".1.3.6.1.4.1.110901.1.2.1.1.1.2")
    for oid, val in rows:
        base_oid = ".1.3.6.1.4.1.110901.1.2.1.1.1.2"
        idx = oid[len(base_oid) + 1:]
        elem_oid = ".1.3.6.1.4.1.110901.1.2.1.1.1.1" + "." + idx
        elem = _snmp_get(ctx, community, host, elem_oid)
        element_id = elem if elem != None else idx
        nm = _item_name("Library", element_id)
        if nm == item:
            state, summary = _status_result(val)
            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": "OK" if state == 0 else ("WARN" if state == 1 else ("CRIT" if state == 2 else "UNKNOWN")),
                    "metrics": {},
                    "details": summary,
                },
            }
    return {"changed": False, "msg": "no such item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def _discover_subcheck(ctx, community, host, name, base, col_id, col_reading):
    # generic discovery over a status table: base col col_reading for value, col_id for index
    rows = _snmp_walk(ctx, community, host, base + "." + col_reading)
    discovered = []
    for oid, val in rows:
        idx = oid[len(base + "." + col_reading) + 1:]
        elem = _snmp_get(ctx, community, host, base + "." + col_id + "." + idx)
        element_id = elem if elem != None else idx
        item = _item_name(name, element_id)
        discovered.append({"item": item, "params": {}, "metrics": ["state"]})
    return discovered

def _check_subcheck(ctx, community, host, name, base, col_id, col_reading, item):
    rows = _snmp_walk(ctx, community, host, base + "." + col_reading)
    for oid, val in rows:
        idx = oid[len(base + "." + col_reading) + 1:]
        elem = _snmp_get(ctx, community, host, base + "." + col_id + "." + idx)
        element_id = elem if elem != None else idx
        nm = _item_name(name, element_id)
        if nm == item:
            state, summary = _status_result(val)
            return {"changed": False, "msg": summary, "data": {"state": "OK" if state == 0 else ("WARN" if state == 1 else ("CRIT" if state == 2 else "UNKNOWN")), "metrics": {}, "details": summary}}
    return {"changed": False, "msg": "no such item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def _discover_objects(ctx, community, host):
    # section[4] -> archive objects count, remaining, total size
    base = ".1.3.6.1.4.1.110901.1.4"
    obj = _snmp_get(ctx, community, host, base + ".2.0")
    rem = _snmp_get(ctx, community, host, base + ".4.0")
    tot = _snmp_get(ctx, community, host, base + ".5.0")
    if obj != None and rem != None and tot != None:
        return [{"item": "", "params": {}, "metrics": ["managed_object_count", "storage_used"]}]
    return []

def _check_objects(ctx, community, host):
    base = ".1.3.6.1.4.1.110901.1.4"
    obj = _snmp_get(ctx, community, host, base + ".2.0")
    rem = _snmp_get(ctx, community, host, base + ".4.0")
    tot = _snmp_get(ctx, community, host, base + ".5.0")
    if obj != None and rem != None and tot != None:
        GB = 1024 * 1024 * 1024
        object_count = int(obj)
        remaining_size = int(rem)
        total_size = int(tot)
        msg = "managed objects: %d, remaining size: %d GB of %d GB" % (object_count, remaining_size, total_size)
        used = (total_size - remaining_size) * GB
        return {"changed": False, "msg": msg, "data": {"state": "OK", "metrics": {"managed_object_count": object_count, "storage_used": used}, "details": msg}}
    return {"changed": False, "msg": "no diva object data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def _discover_tapes(ctx, community, host):
    base = ".1.3.6.1.4.1.110901.1.4"
    val = _snmp_get(ctx, community, host, base + ".3.0")
    if val != None:
        return [{"item": "", "params": {"levels_lower": (5, 1)}, "metrics": ["tapes_free"]}]
    return []

def _check_tapes(ctx, community, host, params):
    base = ".1.3.6.1.4.1.110901.1.4"
    val = _snmp_get(ctx, community, host, base + ".3.0")
    if val == None:
        return {"changed": False, "msg": "no diva tape data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    blank_tapes = int(val)
    levels_lower = params.get("levels_lower", (5, 1))
    warn = levels_lower[0]
    crit = levels_lower[1]
    state = "OK"
    if blank_tapes <= crit:
        state = "CRIT"
    elif blank_tapes <= warn:
        state = "WARN"
    msg = "Blank tapes: %d" % blank_tapes
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"tapes_free": blank_tapes}, "details": msg}}

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    check_name = params.get("check_name", "oracle_diva_csm")
    item = params.get("item", "")

    if params.get("_discover"):
        if check_name == "oracle_diva_csm":
            return {"changed": False, "msg": "discovered", "data": {"discovery": _discover_status(ctx, community, host)}}
        elif check_name == "oracle_diva_csm_drive":
            discovered = _discover_subcheck(ctx, community, host, "Drive", ".1.3.6.1.4.1.110901.1.2.2.1.1", "3", "8")
            return {"changed": False, "msg": "discovered %d items" % len(discovered), "data": {"discovery": discovered}}
        elif check_name == "oracle_diva_csm_actor":
            discovered = _discover_subcheck(ctx, community, host, "Actor", ".1.3.6.1.4.1.110901.1.3.1.1", "2", "4")
            return {"changed": False, "msg": "discovered %d items" % len(discovered), "data": {"discovery": discovered}}
        elif check_name == "oracle_diva_csm_archive":
            discovered = _discover_subcheck(ctx, community, host, "Manager", ".1.3.6.1.4.1.110901.1.4", "1", "2")
            return {"changed": False, "msg": "discovered %d items" % len(discovered), "data": {"discovery": discovered}}
        elif check_name == "oracle_diva_csm_objects":
            discovered = _discover_objects(ctx, community, host)
            return {"changed": False, "msg": "discovered %d items" % len(discovered), "data": {"discovery": discovered}}
        elif check_name == "oracle_diva_csm_tapes":
            discovered = _discover_tapes(ctx, community, host)
            return {"changed": False, "msg": "discovered %d items" % len(discovered), "data": {"discovery": discovered}}
        return {"changed": False, "msg": "unknown check", "data": {"discovery": []}}

    # Check mode
    if check_name == "oracle_diva_csm":
        return _check_status(ctx, community, host, item)
    elif check_name == "oracle_diva_csm_drive":
        return _check_subcheck(ctx, community, host, "Drive", ".1.3.6.1.4.1.110901.1.2.2.1.1", "3", "8", item)
    elif check_name == "oracle_diva_csm_actor":
        return _check_subcheck(ctx, community, host, "Actor", ".1.3.6.1.4.1.110901.1.3.1.1", "2", "4", item)
    elif check_name == "oracle_diva_csm_archive":
        return _check_subcheck(ctx, community, host, "Manager", ".1.3.6.1.4.1.110901.1.4", "1", "2", item)
    elif check_name == "oracle_diva_csm_objects":
        return _check_objects(ctx, community, host)
    elif check_name == "oracle_diva_csm_tapes":
        return _check_tapes(ctx, community, host, params)
    return {"changed": False, "msg": "unknown check", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}