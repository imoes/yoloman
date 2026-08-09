# Huawei WLC CPU check — translated to Starlark
# Source: checkmk.huawei_wlc_devs_cpu
# Reads .1.3.6.1.4.1.2011.5.25.31.1.1.2.1.13 (device name) and .1.3.6.1.4.1.2011.5.25.31.1.1.1.1.5 (cpu_percent)
# Detection OID: .1.3.6.1.2.1.1.2.0 == .1.3.6.1.4.1.2011.2.240.17

def _snmp_value_to_str(value_str):
    # Parse "STRING: \"value\"" or "Gauge32: 12" etc. — keep only the raw value part
    # Example: 'STRING: "AP001"' -> 'AP001', 'Gauge32: 45' -> '45'
    idx = value_str.find(": ")
    if idx == -1:
        return value_str.strip()
    val_part = value_str[idx+2:].strip()
    # Strip double quotes if present
    if len(val_part) >= 2 and val_part[0] == '"' and val_part[-1] == '"':
        val_part = val_part[1:-1]
    return val_part

def main(ctx, params):
    # Configuration
    base_oid = ".1.3.6.1.4.1.2011.5.25.31.1.1"
    name_oid = base_oid + ".2.1.13"   # WLC-AP-DEV-MIB::wlcApDevName
    cpu_oid  = base_oid + ".1.1.5"    # WLC-AP-DEV-MIB::wlcApDevCpuUsage
    mem_oid  = base_oid + ".1.1.7"    # WLC-AP-DEV-MIB::wlcApDevMemUsage (for completeness, not used here)

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn = 80.0
    crit = 90.0
    if params.get("levels") != None:
        levels = params.get("levels")
        if type(levels) == "list" and len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]

    if params.get("_discover"):
        # Discovery: walk device names and check for CPU presence
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid + ".2.1.13"
        ], mutates=False)

        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            val = _snmp_value_to_str(parts[1])
            if val:
                items.append({"item": val, "params": {"levels": [80.0, 90.0]}, "metrics": ["cpu_percent"]})

        return {"changed": False, "msg": "discovered %d devices" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item provided",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch both name and CPU OID to match item and get CPU value
    # We need to retrieve (name, cpu) pairs for all devices and find our item
    # First get all names
    res_names = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid + ".2.1.13"
    ], mutates=False)

    name_map = {}
    for line in res_names.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_name = parts[0]
        val = _snmp_value_to_str(parts[1])
        if val:
            name_map[oid_name] = val

    # Now get CPU usage for all devices (same OIDs as names, but different base)
    res_cpu = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid + ".1.1.5"
    ], mutates=False)

    cpu_map = {}
    for line in res_cpu.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        # Strip leading dots: .1.3.6.1.4.1.2011.5.25.31.1.1.2.1.13.X -> .2.1.13.X
        oid_base = parts[0]
        # Match by index suffix — find matching index in name_map
        idx = oid_base.rfind(".")
        if idx == -1:
            continue
        suffix = oid_base[idx:]   # e.g., ".1", ".2"
        # Try to find matching name entry
        for name_oid_full, dev_name in name_map.items():
            if name_oid_full.endswith(suffix):
                if dev_name == item:
                    val = _snmp_value_to_str(parts[1])
                    cpu_val = None
                    if val != "":
                        if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
                            cpu_val = float(val)
                    cpu_map[item] = cpu_val
                break

    data = cpu_map.get(item)
    if data == None:
        return {"changed": False, "msg": "device not found or no CPU data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Compute state
    state = "OK"
    if data >= crit:
        state = "CRIT"
    elif data >= warn:
        state = "WARN"

    return {"changed": False, "msg": "CPU Usage: %f%%" % data,
            "data": {"state": state, "metrics": {"cpu_percent": data}, "details": ""}}