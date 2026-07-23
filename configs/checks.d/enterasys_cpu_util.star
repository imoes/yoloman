# ===== module-level constants =====
OID_BASE = ".1.3.6.1.4.1.5624.1.2.49.1.1.1.1"
OID_END = ".1.3.6.1.4.1.5624.1.2.49.1.1.1.1"
OID_UTIL = "3"

# ===== helper functions =====
def _snmp_walk_section(ctx, community, host):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        OID_BASE
    ], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    section = []
    for line in lines:
        # Format: OID.ending = STRING: "core_name" or OID.ending = INTEGER: value
        # We need to walk both OIDEnd (core name) and OID 3 (util)
        # But snmpwalk on base only returns first OID; we must use OIDEnd explicitly
        pass  # We'll do two walks below instead
    return section

def _snmp_get_oid(ctx, community, host, base_oid):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid
    ], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    result = []
    for line in lines:
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        # Extract value after ": "
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part.strip()
        result.append((oid_full, value))
    return result

def _snmp_walk_core_utils(ctx, community, host):
    # We need to fetch core names (OIDEnd) and util (OID 3) per core
    # First walk OIDEnd to get core identifiers
    res_cores = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        OID_BASE + ".1"  # OIDEnd is first OID in tree
    ], mutates=False)
    cores = {}
    for line in res_cores.stdout.splitlines():
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part.strip()
        # Extract core name by removing trailing .1 (the OID index)
        # OID format: ...base.1.index
        # We need to strip to get "index" and then core name
        # Actually, the core name IS the value; the OIDEnd maps to core identifier
        if value:
            # Extract index from OID: ...base.1.<index>
            index = oid_full.rsplit(".", 1)[-1]
            cores[index] = value

    # Now fetch util values
    res_utils = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        OID_BASE + "." + OID_UTIL
    ], mutates=False)
    utils = {}
    for line in res_utils.stdout.splitlines():
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part.strip()
        # Extract index from OID: ...base.3.<index>
        index = oid_full.rsplit(".", 1)[-1]
        if index in cores and value.isdigit():
            utils[index] = int(value)

    # Combine: for each core, get (core_name[:-2], util)
    section = []
    for index, util in utils.items():
        if index in cores:
            core_name = cores[index]
            # Remove trailing characters as in Checkmk: [:-2]
            item_name = core_name[:-2] if len(core_name) >= 2 else core_name
            section.append([item_name, str(util)])
    return section

def _apply_threshold(util_value, warn, crit):
    if util_value >= crit:
        return "CRIT"
    elif util_value >= warn:
        return "WARN"
    else:
        return "OK"

# ===== main function =====
def main(ctx, params):
    # Get connection parameters
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode
    if params.get("_discover"):
        section = _snmp_walk_core_utils(ctx, community, host)
        out = []
        for entry in section:
            item_name = entry[0]
            # Suggest params with Checkmk defaults (levels as tuple: (warn, crit))
            # Checkmk default: {"levels": (90.0, 95.0)}
            out.append({
                "item": item_name,
                "params": {"levels": [90.0, 95.0]},
                "metrics": ["util"]
            })
        return {
            "changed": False,
            "msg": "discovered %d cores" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: process one item
    item = params.get("item", "")
    section = _snmp_walk_core_utils(ctx, community, host)

    # Find matching core
    util_value = None
    for core, util in section:
        if core == item:
            util_value = int(util) / 10.0
            break

    # If not found, return UNKNOWN
    if util_value == None:
        return {
            "changed": False,
            "msg": "core not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Get thresholds from params (Checkmk defaults)
    levels = params.get("levels", [90.0, 95.0])
    warn = levels[0] if len(levels) >= 1 else 90.0
    crit = levels[1] if len(levels) >= 2 else 95.0

    # Determine state
    state = _apply_threshold(util_value, warn, crit)
    msg = "CPU utilization %f%%" % util_value

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"util": util_value},
            "details": ""
        }
    }
