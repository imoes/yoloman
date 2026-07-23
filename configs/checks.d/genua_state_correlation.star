# ===== Starlark module: genua_state_correlation =====

# Map state codes to human-readable names
STATE_NAMES = {
    "0": "init",
    "1": "backup",
    "2": "master",
}

# Helper to parse SNMP output lines
def _parse_snmp_output(out):
    items = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        last_dot = oid_part.rfind(".")
        if last_dot == -1:
            continue
        index_str = oid_part[last_dot+1:]
        if not index_str.isdigit():
            continue
        index = int(index_str)
        if value_part.startswith("INTEGER: "):
            value = value_part[9:]
        elif value_part.startswith("STRING: "):
            val = value_part[8:]
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            value = val
        else:
            value = value_part
        items[index] = value
    return items

# Helper to fetch and parse section data
def _get_section(ctx):
    # Try primary base OID first
    base = ".1.3.6.1.4.1.3137.2.1.2.1"
    res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".1"], mutates=False)
    res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".2"], mutates=False)
    res3 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".3"], mutates=False)
    res4 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".4"], mutates=False)
    res7 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".7"], mutates=False)
    
    # If primary fails, try alternative base
    if res1.rc != 0:
        base = ".1.3.6.1.4.1.3717.2.1.2.1"
        res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".1"], mutates=False)
        res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".2"], mutates=False)
        res3 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".3"], mutates=False)
        res4 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".4"], mutates=False)
        res7 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", base + ".7"], mutates=False)
    
    # If still failed, return empty section
    if res1.rc != 0 or res2.rc != 0 or res3.rc != 0 or res4.rc != 0 or res7.rc != 0:
        return []
    
    idxs1 = _parse_snmp_output(res1.stdout)
    idxs2 = _parse_snmp_output(res2.stdout)
    idxs3 = _parse_snmp_output(res3.stdout)
    idxs4 = _parse_snmp_output(res4.stdout)
    idxs7 = _parse_snmp_output(res7.stdout)
    
    all_indices = set(idxs1.keys()) | set(idxs2.keys()) | set(idxs3.keys()) | set(idxs4.keys()) | set(idxs7.keys())
    section = []
    for idx in sorted(all_indices):
        if1 = idxs1.get(idx)
        if2 = idxs2.get(idx)
        if3 = idxs3.get(idx)
        if4 = idxs4.get(idx)
        if7 = idxs7.get(idx)
        # Skip if ifCarpState is not valid
        if if7 not in ["0", "1", "2"]:
            continue
        # Skip if any required value is missing
        if if1 == None or if2 == None or if3 == None or if4 == None or if7 == None:
            continue
        section.append([if1, if2, if3, if4, if7])
    return section

def _discover_genua_state(ctx):
    section = _get_section(ctx)
    if not section:
        return []
    
    numifs = 0
    for row in section:
        ifCarpState = row[4]
        if ifCarpState in ["0", "1", "2"]:
            numifs += 1
    
    if numifs > 1:
        return [{"item": "", "params": {}, "metrics": []}]
    return []

def _check_genua_state(ctx, params):
    section = _get_section(ctx)
    
    # Handle invalid output
    if not section:
        return {"changed": False, "msg": "Invalid Output from Agent", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    carp_info = []
    for row in section:
        ifType = row[2]
        if ifType == "6":
            carp_info.append(row)
    
    # If no carp interfaces, report UNKNOWN
    if not carp_info:
        return {"changed": False, "msg": "No carp interfaces found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Count states
    carp_states = {"0": 0, "1": 0, "2": 0}
    first_state = carp_info[0][4]
    state = 0
    
    for elem in carp_info:
        carp_state = elem[4]
        if carp_state in carp_states:
            carp_states[carp_state] += 1
        # Critical if states differ
        if first_state != carp_state:
            state = 2
    
    # Build output
    output_parts = []
    for i in ["0", "1", "2"]:
        name = STATE_NAMES.get(i, i)
        output_parts.append("%s:%d" % (name, carp_states[i]))
    output = "Number of carp IFs in states " + " ".join(output_parts)
    
    return {"changed": False, "msg": output, "data": {"state": "OK" if state == 0 else ("WARN" if state == 1 else "CRIT"), "metrics": {}, "details": ""}}

def main(ctx, params):
    # If in discovery mode
    if params.get("_discover") != None:
        items = _discover_genua_state(ctx)
        return {"changed": False, "msg": "discovered %d items" % len(items), "data": {"discovery": items}}
    
    # Check mode
    return _check_genua_state(ctx, params)
