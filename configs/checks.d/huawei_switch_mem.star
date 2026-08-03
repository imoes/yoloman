# Huawei switch memory utilization check (read-only).
# Monitors per-MPU-board memory usage via SNMP on Huawei switches.

def _parse_huawei_mem(tables):
    # tables: single value, two StringTables [entities_info, values_info]
    if not tables:
        return {}
    info = tables
    entities_info = info[0]
    values_info = info[1]
    stack_member_number = 0
    entities_per_member = {}
    entity_name_start = "mpu board"
    for entity_line in entities_info:
        if len(entity_line) < 2:
            continue
        lower_entity_name = entity_line[1].lower()
        ent_physical_index = entity_line[0]
        if lower_entity_name.startswith(entity_name_start):
            stack_member_number += 1
            entities_per_member[stack_member_number] = []
        if lower_entity_name.startswith(entity_name_start.lower()):
            value = None
            for value_line in values_info:
                if len(value_line) >= 2 and value_line[0] == ent_physical_index:
                    value = value_line[1]
                    break
            entities_per_member[stack_member_number].append({
                "physical_index": ent_physical_index,
                "stack_member": stack_member_number,
                "value": value,
            })
    items = {}
    for member_number, entities in entities_per_member.items():
        for entity_idx, entity in enumerate(entities):
            item_name = str(member_number)
            item_name += "/" + str(entity_idx + 1)
            items[item_name] = entity
    return items


def _parse_table(res, column_oid):
    rows = []
    if res.rc != 0 or not res.stdout:
        return rows
    col_prefix = column_oid + "."
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid = sp[0]
        val = sp[1]
        if not oid.startswith(col_prefix):
            continue
        idx = oid[len(column_oid) + 1:]
        rows.append([idx, val])
    return rows


def _is_float(s):
    if s == None:
        return False
    s = s.strip()
    if s == "" or s.count(".") > 1:
        return False
    if s.startswith(".") or s.startswith("-") or s.startswith("+"):
        body = s[1:]
    else:
        body = s
    if body == "":
        return False
    for ch in body:
        if not (ch.isdigit() or ch == "."):
            return False
    return True


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", (80.0, 90.0))
    if type(levels) == "tuple" and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn", 80.0)
        crit = params.get("crit", 90.0)

    # Probe for a Huawei switch via sysObjectID.
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "device not reachable / not present", "data": {"discovery": [], "details": ""}}
        return {"changed": False, "msg": "device not reachable / not present",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_oid = sys_res.stdout.strip()
    if not sys_oid.startswith(".1.3.6.1.4.1.2011.2.23"):
        if params.get("_discover"):
            return {"changed": False, "msg": "not a Huawei switch", "data": {"discovery": [], "details": ""}}
        return {"changed": False, "msg": "not a Huawei switch",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch entity names and values (ENTITY-MIB entPhysicalName / Huawei memory).
    names_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.47.1.1.1.1.7"],
        mutates=False,
    )
    values_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.7"],
        mutates=False,
    )

    entities_info = _parse_table(names_res, ".1.3.6.1.2.1.47.1.1.1.1.7")
    values_info = _parse_table(values_res, ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.7")

    section = _parse_huawei_mem([entities_info, values_info])

    if params.get("_discover"):
        discovery = []
        for item in sorted(section.keys()):
            entity = section[item]
            if entity["value"] == None:
                continue
            discovery.append({
                "item": item,
                "params": {"warn": warn, "crit": crit},
                "metrics": ["mem_used_percent"],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery, "details": ""}}

    item = params.get("item", "")
    entity = section.get(item)
    if entity == None or entity["value"] == None:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not _is_float(entity["value"]):
        return {"changed": False, "msg": "invalid memory value: " + str(entity["value"]),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    mem = float(entity["value"].strip())

    state = "OK"
    if mem >= crit:
        state = "CRIT"
    elif mem >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "Usage %s%%" % str(mem),
            "data": {"state": state, "metrics": {"mem_used_percent": mem}, "details": ""}}