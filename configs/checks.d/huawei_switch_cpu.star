# ===== Starlark check: huawei_switch_cpu =====
# Read-only check for Huawei switch CPU utilization via SNMP
# Translation of Checkmk check: cmk.plugins.huawei.agent_sections.huawei_switch_cpu

# Module-level constants
_CPU_OID_BASE = ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1"
_ENTITY_OID_BASE = ".1.3.6.1.2.1.47.1.1.1.1"
_HUAWEI_MPU_BOARD_NAME_START = "mpu board"

def _snmp_walk(ctx, community, host, base_oid):
    # Walk a base OID and parse output lines into dict of {oid: value}
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed for %s: %s" % (base_oid, res.stderr))
    
    result = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value_part = parts[1].strip()
        # Extract value after type prefix (e.g., "INTEGER: 22" -> "22")
        colon_pos = value_part.find(": ")
        if colon_pos >= 0:
            value = value_part[colon_pos + 2:].strip().strip('"')
        else:
            value = value_part
        result[oid] = value
    return result

def _parse_entities_and_values(ctx, community, host):
    # Walk entityMIB entPhysicalName (base .1.3.6.1.2.1.47.1.1.1.1 + OIDEnd + "7")
    entity_oids = _snmp_walk(ctx, community, host, _ENTITY_OID_BASE)
    
    # Walk Huawei CPU utilization values (base .1.3.6.1.4.1.2011.5.25.31.1.1.1.1 + OIDEnd + "5")
    value_oids = _snmp_walk(ctx, community, host, _CPU_OID_BASE)
    
    # Map physical index to entity name and value
    entities_per_member = {}
    stack_member_number = 0
    index_to_value = {}   # index -> value string
    
    # Process entity entries
    for oid, name in entity_oids.items():
        # OID format: base.OIDEnd -> extract last component as index
        parts = oid.split(".")
        if len(parts) < 10:
            continue
        idx = parts[-1]
        
        lower_name = name.lower()
        
        # Detect new stack member (mpu board)
        if lower_name.startswith(_HUAWEI_MPU_BOARD_NAME_START):
            stack_member_number += 1
            if stack_member_number not in entities_per_member:
                entities_per_member[stack_member_number] = {}
        
        # Track matching entities
        if lower_name.startswith(_HUAWEI_MPU_BOARD_NAME_START) and stack_member_number > 0:
            # Find corresponding value
            val = None
            # value_oid: base + OIDEnd + "5" -> same base + index + "5"
            value_oid_prefix = _CPU_OID_BASE + "." + idx + ".5"
            # Look for exact match in value_oids
            for v_oid, v_val in value_oids.items():
                if v_oid == value_oid_prefix:
                    val = v_val
                    break
            
            entities_per_member[stack_member_number][idx] = val
    
    # Build item dict
    items = {}
    for member, entities in entities_per_member.items():
        for idx, val in entities.items():
            item_name = str(member)
            # Add sub index
            item_name += "/" + str(idx)
            items[item_name] = val
    
    return items

def _check_cpu_util(util, params):
    # Implement check_cpu_util logic: OK/WARN/CRIT based on levels
    if util == None or util == "":
        return "UNKNOWN", "no value"
    
    # Guard instead of try/except: check if value looks numeric
    clean_val = util.strip()
    is_number = clean_val.replace(".", "").replace("-", "").isdigit() and clean_val.count(".") <= 1
    if not is_number:
        return "UNKNOWN", "invalid value: %s" % util
    
    util_val = float(clean_val)
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]
    
    if util_val >= crit:
        return "CRIT", "%f%%" % util_val
    elif util_val >= warn:
        return "WARN", "%f%%" % util_val
    else:
        return "OK", "%f%%" % util_val

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        items = _parse_entities_and_values(ctx, community, host)
        discovery_items = []
        for item, value in items.items():
            # Only discover if value is present
            if value != None:
                discovery_items.append({
                    "item": item,
                    "params": {"levels": (80.0, 90.0)},
                    "metrics": ["cpu_util"]
                })
        return {
            "changed": False,
            "msg": "discovered %d CPU items" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    items = _parse_entities_and_values(ctx, community, host)
    
    if item == "" or item not in items:
        return {
            "changed": False,
            "msg": "item not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    util = items[item]
    state, details = _check_cpu_util(util, params)
    
    # Parse value for metrics (if possible)
    metrics = {}
    clean_val = util.strip() if util != None else ""
    is_number = clean_val.replace(".", "").replace("-", "").isdigit() and clean_val.count(".") <= 1 if clean_val else False
    if is_number:
        metrics["cpu_util"] = float(clean_val)
    
    return {
        "changed": False,
        "msg": "%s" % details,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details
        }
    }