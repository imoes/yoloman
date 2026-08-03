def _discover_huawei_switch_temp(ctx, params):
    # Verify this is a Huawei switch via sysObjectID
    sys_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_res.rc != 0:
        return {"changed": False, "msg": "not a huawei switch", "data": {"discovery": [], "host_labels": {}}}
    
    sys_oid = sys_res.stdout.strip()
    if not sys_oid.find(".1.3.6.1.4.1.2011.2.23") >= 0:
        return {"changed": False, "msg": "not a huawei switch", "data": {"discovery": [], "host_labels": {}}}
    
    # Walk ENTITY-MIB entPhysicalName (.1.3.6.1.2.1.47.1.1.1.1.7)
    ent_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), ".1.3.6.1.2.1.47.1.1.1.1.7"], mutates=False)
    if ent_res.rc != 0:
        return {"changed": False, "msg": "entity mib not available", "data": {"discovery": [], "host_labels": {}}}
    
    # Walk Huawei temp value column (.1.3.6.1.4.1.2011.5.25.31.1.1.1.1.11)
    val_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.11"], mutates=False)
    if val_res.rc != 0:
        return {"changed": False, "msg": "temperature values not available", "data": {"discovery": [], "host_labels": {}}}
    
    # Parse entity names: OID.index VALUE -> (index, name)
    entities = []
    for line in ent_res.stdout.splitlines():
        space = line.find(" ")
        if space < 0:
            continue
        oid = line[:space]
        name = line[space+1:]
        # strip quotes if present
        if len(name) >= 2 and name[0] == '"' and name[-1] == '"':
            name = name[1:-1]
        # index is the entPhysicalIndex
        base = ".1.3.6.1.2.1.47.1.1.1.1.7"
        if oid.startswith(base + "."):
            index = oid[len(base)+1:]
        else:
            index = oid
        entities.append((index, name))
    
    # Parse values: OID.index VALUE -> (index, value)
    values = {}
    for line in val_res.stdout.splitlines():
        space = line.find(" ")
        if space < 0:
            continue
        oid = line[:space]
        val = line[space+1:]
        base = ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.11"
        if oid.startswith(base + "."):
            index = oid[len(base)+1:]
        else:
            index = oid
        values[index] = val
    
    # Find mpu board entities, match to values, group by stack member
    stack_member_number = 0
    entities_per_member = {}
    for entity_line in entities:
        ent_physical_index = entity_line[0]
        entity_name = entity_line[1].lower()
        
        if entity_name.startswith("mpu board"):
            stack_member_number += 1
            entities_per_member[stack_member_number] = []
        
        if entity_name.startswith("mpu board"):
            value = values.get(ent_physical_index)
            entities_per_member[stack_member_number].append(value)
    
    # Build discovery items: since multiple_entities_per_member == False,
    # item names are just stack_member_number, and each member has one entity
    discovery = []
    for member_number in sorted(entities_per_member.keys()):
        entity_list = entities_per_member[member_number]
        for entity_idx, entity in enumerate(entity_list):
            item_name = str(member_number)
            # multiple_entities_per_member == False (entity_name_start == mpu board start)
            # so no sub-index added
            discovery.append({
                "item": item_name,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["temperature"],
            })
    
    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {
            "discovery": discovery,
            "host_labels": {"cmk/vendor": "huawei", "cmk/device_type": "switch"},
        },
    }

def _check_huawei_switch_temp(ctx, params):
    item = params.get("item", "")
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if type(levels) == "tuple" and len(levels) >= 2 else 80.0
    crit = levels[1] if type(levels) == "tuple" and len(levels) >= 2 else 90.0
    
    # Verify this is a Huawei switch
    sys_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_res.rc != 0:
        return {"changed": False, "msg": "not a huawei switch",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sys_oid = sys_res.stdout.strip()
    if sys_oid.find(".1.3.6.1.4.1.2011.2.23") < 0:
        return {"changed": False, "msg": "not a huawei switch",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Walk entPhysicalName
    ent_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), ".1.3.6.1.2.1.47.1.1.1.1.7"], mutates=False)
    if ent_res.rc != 0:
        return {"changed": False, "msg": "entity mib not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Walk Huawei temp values
    val_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.11"], mutates=False)
    if val_res.rc != 0:
        return {"changed": False, "msg": "temperature values not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse entities
    entities = []
    ent_base = ".1.3.6.1.2.1.47.1.1.1.1.7"
    for line in ent_res.stdout.splitlines():
        space = line.find(" ")
        if space < 0:
            continue
        oid = line[:space]
        name = line[space+1:]
        if len(name) >= 2 and name[0] == '"' and name[-1] == '"':
            name = name[1:-1]
        if oid.startswith(ent_base + "."):
            index = oid[len(ent_base)+1:]
        else:
            index = oid
        entities.append((index, name))
    
    # Parse values
    values = {}
    val_base = ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.11"
    for line in val_res.stdout.splitlines():
        space = line.find(" ")
        if space < 0:
            continue
        oid = line[:space]
        val = line[space+1:]
        if oid.startswith(val_base + "."):
            index = oid[len(val_base)+1:]
        else:
            index = oid
        values[index] = val
    
    # Find mpu board entities, match to values, group by stack member
    stack_member_number = 0
    entities_per_member = {}
    for entity_line in entities:
        ent_physical_index = entity_line[0]
        entity_name = entity_line[1].lower()
        
        if entity_name.startswith("mpu board"):
            stack_member_number += 1
            entities_per_member[stack_member_number] = []
        
        if entity_name.startswith("mpu board"):
            value = values.get(ent_physical_index)
            entities_per_member[stack_member_number].append(value)
    
    # Build item dict: item_name -> value
    # multiple_entities_per_member == False since entity_name_start == mpu board start
    item_value = None
    for member_number in sorted(entities_per_member.keys()):
        entity_list = entities_per_member[member_number]
        for entity_idx, entity in enumerate(entity_list):
            item_name = str(member_number)
            if item_name == item:
                item_value = entity
                break
    
    if item_value == None:
        return {"changed": False, "msg": "no temperature data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp_str = item_value
    if temp_str == None:
        return {"changed": False, "msg": "no temperature data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Convert to float
    temp = float(temp_str)
    
    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
    return {"changed": False, "msg": "Temperature %s: %f C" % (item, temp),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}

def main(ctx, params):
    if params.get("_discover"):
        return _discover_huawei_switch_temp(ctx, params)
    return _check_huawei_switch_temp(ctx, params)