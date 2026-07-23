# ===== Starlark check module: hp_hh3c_ext =====
# Translated from Checkmk plugin cmk.plugins.hp_hh3c_ext.agent_based.hp_hh3c_ext
# Reads temperature, CPU, memory, and status info via SNMP

def main(ctx, params):
    # ===== constants =====
    SNMP_BASE_ENTITY_EXT = ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
    SNMP_BASE_ENTITY = ".1.3.6.1.2.1.47.1.1.1.1"
    
    # ===== discovery mode =====
    if params.get("_discover"):
        discovered = []

        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            SNMP_BASE_ENTITY_EXT
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        entity_info = {}
        res2 = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            SNMP_BASE_ENTITY
        ], mutates=False)
        if res2.rc == 0:
            for line in res2.stdout.splitlines():
                parts = line.strip().split()
                if len(parts) >= 2:
                    oid_end = parts[0].rsplit(".", 1)[-1]
                    name = parts[1]
                    # strip quotes if present
                    if name.startswith('"') and name.endswith('"'):
                        name = name[1:-1]
                    entity_info[oid_end] = name

        # Parse temp/cpu/mem data - guard all conversions
        for line in res.stdout.splitlines():
            fields = line.strip().split()
            if len(fields) < 8:
                continue
            idx = fields[0].rsplit(".", 1)[-1] if "." in fields[0] else ""
            if not idx.isdigit():
                continue
            
            name = entity_info.get(idx, "")
            item_name = ("%s %s" % (name, idx)).strip()

            temperature = fields[5]
            mem_size = fields[6]
            if not temperature.isdigit() or not mem_size.isdigit():
                continue
                
            mem_total = int(mem_size)
            temp_val = int(temperature)
            
            if temp_val != 65535 and mem_total > 0:
                discovered.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["temperature"]
                })

        return {"changed": False, "msg": "discovered %d items" % len(discovered),
                "data": {"discovery": discovered}}

    # ===== check mode: temperature =====
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather SNMP data for the item
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        SNMP_BASE_ENTITY_EXT
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": ""}}

    entity_info = {}
    res2 = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        SNMP_BASE_ENTITY
    ], mutates=False)
    if res2.rc == 0:
        for line in res2.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 2:
                oid_end = parts[0].rsplit(".", 1)[-1]
                name = parts[1]
                # strip quotes if present
                if name.startswith('"') and name.endswith('"'):
                    name = name[1:-1]
                entity_info[oid_end] = name

    temperature_value = None
    for line in res.stdout.splitlines():
        fields = line.strip().split()
        if len(fields) < 8:
            continue
        idx = fields[0].rsplit(".", 1)[-1] if "." in fields[0] else ""
        if not idx.isdigit():
            continue
            
        name = entity_info.get(idx, "")
        check_item = ("%s %s" % (name, idx)).strip()
        if check_item == item:
            temperature_str = fields[5]
            if temperature_str.isdigit() or (temperature_str.startswith("-") and temperature_str[1:].isdigit()):
                temperature_value = float(temperature_str)
            break

    if temperature_value == None:
        return {"changed": False, "msg": "item not found", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply temperature thresholds (default Checkmk levels)
    warn = params.get("levels", (80.0, 90.0))
    if type(warn) == "list":
        warn_val = float(warn[0]) if str(warn[0]).replace('.','').replace('-','').isdigit() else 80.0
        crit_val = float(warn[1]) if str(warn[1]).replace('.','').replace('-','').isdigit() else 90.0
    else:
        warn_val = 80.0
        crit_val = 90.0

    # Simple temperature check: OK/WARN/CRIT based on absolute thresholds
    state = "CRIT" if temperature_value >= crit_val else ("WARN" if temperature_value >= warn_val else "OK")

    return {
        "changed": False,
        "msg": "Temperature: %f C" % temperature_value,
        "data": {
            "state": state,
            "metrics": {"temperature": temperature_value},
            "details": ""
        }
    }