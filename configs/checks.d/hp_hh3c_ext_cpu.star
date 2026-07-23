# Translated from Checkmk plugin: checkmk.hp_hh3c_ext_cpu
# Reads SNMP data from HP/H3C devices to report CPU utilization per module

# SNMP OIDs for hp_hh3c_ext section (temperature, CPU, memory, status)
_BASE_OID_EXT = ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
_BASE_OID_ENTITY = ".1.3.6.1.2.1.47.1.1.1.1"

# SNMP OIDs extracted from SNMPTree definitions:
# base=".1.3.6.1.4.1.25506.2.6.1.1.1.1"
#   oids=[OIDEnd(), "2", "3", "6", "8", "12", "10"]
#   index, adminState, operState, cpu, memUsage, temperature, memSize
# base=".1.3.6.1.2.1.47.1.1.1.1"
#   oids=[OIDEnd(), OIDCached("2")] -> entityName (index+1)

def _snmp_walk(ctx, community, host, base_oid, oid_suffixes):
    """Perform snmpwalk on a base OID + each suffix and return parsed lines."""
    lines = []
    for suffix in oid_suffixes:
        full_oid = base_oid + "." + suffix
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
        if res.rc == 0:
            lines.extend(res.stdout.splitlines())
    return lines

def _parse_entity_names(ctx, community, host):
    """Parse entity name mapping (index -> name) from entityMIB."""
    lines = _snmp_walk(ctx, community, host, _BASE_OID_ENTITY, ["2"])
    mapping = {}
    for line in lines:
        # Format: .1.3.6.1.2.1.47.1.1.1.1.2.<index> = STRING: "<name>"
        if " = " not in line:
            continue
        oid_part, val_part = line.rsplit(" = ", 1)
        # Extract index from end of OID
        idx_str = oid_part.rsplit(".", 1)[-1]
        # Strip quotes and leading/trailing whitespace from value
        name = val_part.strip().strip('"')
        if name != "" and idx_str.isdigit():
            mapping[idx_str] = name
    return mapping

def _parse_ext_section(ctx, community, host):
    """Parse the hp_hh3c_ext section (CPU, temp, memory, states)."""
    entity_names = _parse_entity_names(ctx, community, host)
    
    # Fetch all required OIDs for the extension table
    base_oid = _BASE_OID_EXT
    suffixes = ["1", "2", "3", "6", "8", "12", "10"]  # index, adminState, operState, cpu, memUsage, temperature, memSize
    
    # Perform a single snmpwalk per OID suffix
    data_by_index = {}
    for suffix in suffixes:
        full_oid = base_oid + "." + suffix
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            if " = " not in line:
                continue
            oid_part, val_part = line.rsplit(" = ", 1)
            idx_str = oid_part.rsplit(".", 1)[-1]
            val_str = val_part.strip()
            if not idx_str.isdigit():
                continue
            if idx_str not in data_by_index:
                data_by_index[idx_str] = {}
            # Map suffix to field name
            if suffix == "1":
                data_by_index[idx_str]["admin"] = val_str
            elif suffix == "2":
                data_by_index[idx_str]["oper"] = val_str
            elif suffix == "3":
                data_by_index[idx_str]["cpu"] = val_str
            elif suffix == "6":
                data_by_index[idx_str]["mem_usage"] = val_str
            elif suffix == "8":
                data_by_index[idx_str]["temperature"] = val_str
            elif suffix == "12":
                data_by_index[idx_str]["mem_size"] = val_str

    # Assemble final section
    section = {}
    for idx_str, data in data_by_index.items():
        name = entity_names.get(idx_str, "")
        if name == "":
            name = ""
        key = "%s %s" % (name, idx_str)
        # Convert numeric fields with guards (no try/except)
        temp_str = data.get("temperature", "65535")
        temp = int(temp_str) if temp_str.isdigit() else 65535
        
        cpu_str = data.get("cpu", "0")
        cpu = int(cpu_str) if cpu_str.isdigit() else 0
        
        mem_size_str = data.get("mem_size", "0")
        mem_size = int(mem_size_str) if mem_size_str.isdigit() else 0
        
        mem_usage_str = data.get("mem_usage", "0")
        mem_usage = float(mem_usage_str) if mem_usage_str.replace(".", "").isdigit() else 0.0

        section[key] = {
            "temp": temp,
            "cpu": cpu,
            "mem_total": mem_size,
            "mem_used": 0.01 * mem_usage * mem_size if mem_size > 0 else 0.0,
            "admin": data.get("admin", "1"),
            "oper": data.get("oper", "1"),
        }
    return section

def _check_cpu_util(ctx, params, cpu_val):
    """Check CPU utilization using Checkmk-style levels (same logic as check_cpu_util)."""
    # Default thresholds (check_default_parameters is empty for cpu_utilization_multiitem)
    warn = params.get("levels", (80.0, 90.0))
    if len(warn) == 2:
        warn_val, crit_val = warn
    else:
        warn_val = 80.0
        crit_val = 90.0

    # Apply thresholds
    if cpu_val >= crit_val:
        state = "CRIT"
    elif cpu_val >= warn_val:
        state = "WARN"
    else:
        state = "OK"
    msg = "CPU %d%%" % cpu_val
    return state, msg, cpu_val

def main(ctx, params):
    if params.get("_discover") == True:
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        section = _parse_ext_section(ctx, community, host)
        
        # Discovery: yield one item per module where mem_total > 0
        discovery = []
        for item, data in section.items():
            if data["mem_total"] > 0:
                # CPU item: metrics = ["cpu_util"]
                discovery.append({
                    "item": item,
                    "params": {},  # empty defaults for cpu_utilization_multiitem
                    "metrics": ["cpu_util"],
                })
        return {
            "changed": False,
            "msg": "discovered %d CPU items" % len(discovery),
            "data": {"discovery": discovery},
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Parse data on-demand (avoid caching; each invocation gets fresh params)
    section = _parse_ext_section(ctx, community, host)
    data = section.get(item)
    
    if data == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    cpu_val = float(data["cpu"])
    state, msg, perf_val = _check_cpu_util(ctx, params, cpu_val)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"cpu_util": perf_val},
            "details": "",
        },
    }