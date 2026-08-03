def _parse_cpu_section(string_table):
    entities_info = string_table[0]
    values_info = string_table[1]
    stack_member_number = 0
    entities_per_member = {}
    for entity_line in entities_info:
        lower_entity_name = entity_line[1].lower()
        ent_physical_index = entity_line[0]
        if lower_entity_name.startswith("mpu board"):
            stack_member_number += 1
            entities_per_member[stack_member_number] = []
        if lower_entity_name.startswith("mpu board"):
            value = None
            for value_line in values_info:
                if value_line[0] == ent_physical_index:
                    value = value_line[1]
            entities_per_member[stack_member_number].append({
                "physical_index": ent_physical_index,
                "stack_member": stack_member_number,
                "value": value,
            })
    items = {}
    for member_number, entities in entities_per_member.items():
        for entity_idx, entity in enumerate(entities):
            item_name = str(member_number) + "/" + str(entity_idx + 1)
            items[item_name] = entity
    return items

def _walk_snmp(ctx, community, host, oid):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {}
    rows = {}
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx < 0:
            continue
        oid_part = line[:idx]
        val_part = line[idx + 1:]
        suffix = oid_part[len(oid):]
        rows[suffix] = val_part
    return rows

def _get_snmp(ctx, community, host, oid):
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, oid
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    return res.stdout.strip()

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_oid_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"
    ], mutates=False)
    if sys_oid_res.rc == 127 or not sys_oid_res.stdout or ".1.3.6.1.4.1.2011.2.23" not in sys_oid_res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "not a Huawei switch", "data": {"discovery": []}}
        return {"changed": False, "msg": "not a Huawei switch", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        entity_base = ".1.3.6.1.2.1.47.1.1.1.1"
        value_base = ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1"
        entities = _walk_snmp(ctx, community, host, entity_base)
        values = _walk_snmp(ctx, community, host, value_base)
        if not entities:
            return {"changed": False, "msg": "no CPU entities found", "data": {"discovery": []}}

        entities_info = []
        for idx, name in entities.items():
            ent_physical_index = idx
            entity_name = name.strip().strip('"')
            entities_info.append([ent_physical_index, entity_name])

        values_info = []
        for idx, raw_val in values.items():
            val = raw_val.strip().strip('"')
            values_info.append([idx, val])

        section = _parse_cpu_section([entities_info, values_info])
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": {"levels": params.get("levels", [80.0, 90.0])},
                "metrics": ["util"],
            })
        return {"changed": False, "msg": "discovered %d CPU items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    entity_base = ".1.3.6.1.2.1.47.1.1.1.1"
    value_base = ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1"
    entities = _walk_snmp(ctx, community, host, entity_base)
    values = _walk_snmp(ctx, community, host, value_base)

    entities_info = []
    for idx, name in entities.items():
        entity_name = name.strip().strip('"')
        entities_info.append([idx, entity_name])

    values_info = []
    for idx, raw_val in values.items():
        val = raw_val.strip().strip('"')
        values_info.append([idx, val])

    section = _parse_cpu_section([entities_info, values_info])
    item_data = section.get(item)
    if item_data == None:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item_data["value"] == None:
        return {"changed": False, "msg": "no CPU value for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val_str = item_data["value"]
    if val_str.lstrip("-").replace(".", "", 1).isdigit():
        util = float(val_str)
    else:
        return {"changed": False, "msg": "invalid CPU value for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", [80.0, 90.0])
    warn = levels[0]
    crit = levels[1]
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "CPU utilization: %f%%" % util,
        "data": {
            "state": state,
            "metrics": {"util": util},
            "details": "CPU utilization %f%% (warn: %f%%, crit: %f%%)" % (util, warn, crit),
        },
    }