# Constants for SNMP OIDs
FJDARYE_POLS_BASE_150 = ".1.3.6.1.4.1.211.1.21.1.150.14.5.2.1"
FJDARYE_POLS_BASE_153 = ".1.3.6.1.4.1.211.1.21.1.153.14.5.2.1"
SYSOID = ".1.3.6.1.2.1.1.2.0"
SYSOID_150 = ".1.3.6.1.4.1.211.1.21.1.150"
SYSOID_153 = ".1.3.6.1.4.1.211.1.21.1.153"
FJDARYE_POOL_OID_NUMBER = "1"
FJDARYE_POOL_OID_CAPACITY = "3"
FJDARYE_POOL_OID_USAGE = "4"

def main(ctx, params):
    if params.get("_discover"):
        # Detect device family via sysObjectID
        res_sys = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                           params.get("host", "localhost"), SYSOID], mutates=False)
        sysoid = ""
        if res_sys.rc == 0 and res_sys.stdout.strip() != "":
            parts = res_sys.stdout.strip().split(" = ")
            if len(parts) >= 2:
                sysoid = parts[-1].strip()

        base_oids = []
        if sysoid == SYSOID_150:
            base_oids.append(FJDARYE_POLS_BASE_150)
        elif sysoid == SYSOID_153:
            base_oids.append(FJDARYE_POLS_BASE_153)

        if not base_oids:
            return {"changed": False, "msg": "discovered 0 pools (unsupported device)",
                    "data": {"discovery": []}}

        # Walk all applicable pools
        out = []
        for base_oid in base_oids:
            res_walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                                params.get("host", "localhost"), base_oid + "." + FJDARYE_POOL_OID_NUMBER,
                                base_oid + "." + FJDARYE_POOL_OID_CAPACITY,
                                base_oid + "." + FJDARYE_POOL_OID_USAGE], mutates=False)
            if res_walk.rc != 0:
                continue

            lines = res_walk.stdout.splitlines()
            pool_data = {}
            # Parse snmpwalk lines: "<OID> = INTEGER: value" or "<OID> = GAUGE: value"
            for line in lines:
                if not line:
                    continue
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                oid_full = parts[0].strip()
                value_str = parts[1].strip()
                if ":" in value_str:
                    value_str = value_str.split(":", 1)[1].strip()

                # Extract index from OID tail (last number after the base)
                tail = oid_full[len(base_oid) + 1:]
                idx = ""
                for ch in tail:
                    if ch.isdigit():
                        idx += ch
                    elif ch == ".":
                        break

                if not idx:
                    continue
                if idx not in pool_data:
                    pool_data[idx] = {"number": "", "capacity": "", "usage": ""}
                if "1" in oid_full and oid_full.endswith(FJDARYE_POOL_OID_NUMBER):
                    pool_data[idx]["number"] = value_str
                elif "3" in oid_full and oid_full.endswith(FJDARYE_POOL_OID_CAPACITY):
                    pool_data[idx]["capacity"] = value_str
                elif "4" in oid_full and oid_full.endswith(FJDARYE_POOL_OID_USAGE):
                    pool_data[idx]["usage"] = value_str

            # Build list of pools with numeric IDs
            for idx, data in pool_data.items():
                if data["capacity"] == "" or data["usage"] == "":
                    continue
                # Guard against invalid float values
                cap_str = data["capacity"]
                usage_str = data["usage"]
                if cap_str.replace(".", "").replace("-", "").isdigit() and usage_str.replace(".", "").replace("-", "").isdigit():
                    capacity = float(cap_str)
                    usage = float(usage_str)
                    item = data["number"] if data["number"] else idx
                    out.append({"item": item, "params": {}, "metrics": ["used_percent"]})

        return {"changed": False, "msg": "discovered %d pools" % len(out),
                "data": {"discovery": out}}

    # CHECK mode
    item = params.get("item", "")
    # Detect device family first
    res_sys = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), SYSOID], mutates=False)
    sysoid = ""
    if res_sys.rc == 0 and res_sys.stdout.strip() != "":
        parts = res_sys.stdout.strip().split(" = ")
        if len(parts) >= 2:
            sysoid = parts[-1].strip()

    base_oid = ""
    if sysoid == SYSOID_150:
        base_oid = FJDARYE_POLS_BASE_150
    elif sysoid == SYSOID_153:
        base_oid = FJDARYE_POLS_BASE_153
    else:
        return {"changed": False, "msg": "unsupported device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch pool data by item (match number field)
    res_walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        base_oid + "." + FJDARYE_POOL_OID_NUMBER,
                        base_oid + "." + FJDARYE_POOL_OID_CAPACITY,
                        base_oid + "." + FJDARYE_POOL_OID_USAGE], mutates=False)
    if res_walk.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res_walk.stdout.splitlines()
    pool_data = {}
    for line in lines:
        if not line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value_str = parts[1].strip()
        if ":" in value_str:
            value_str = value_str.split(":", 1)[1].strip()

        tail = oid_full[len(base_oid) + 1:]
        idx = ""
        for ch in tail:
            if ch.isdigit():
                idx += ch
            elif ch == ".":
                break
        if not idx:
            continue
        if idx not in pool_data:
            pool_data[idx] = {"number": "", "capacity": "", "usage": ""}
        if "1" in oid_full and oid_full.endswith(FJDARYE_POOL_OID_NUMBER):
            pool_data[idx]["number"] = value_str
        elif "3" in oid_full and oid_full.endswith(FJDARYE_POOL_OID_CAPACITY):
            pool_data[idx]["capacity"] = value_str
        elif "4" in oid_full and oid_full.endswith(FJDARYE_POOL_OID_USAGE):
            pool_data[idx]["usage"] = value_str

    pool_capacity = 0.0
    pool_usage = 0.0
    found = False
    for idx, data in pool_data.items():
        if data["number"] == item or (data["number"] == "" and item == idx):
            # Guard against invalid float values
            cap_str = data["capacity"]
            usage_str = data["usage"]
            if cap_str.replace(".", "").replace("-", "").isdigit() and usage_str.replace(".", "").replace("-", "").isdigit():
                pool_capacity = float(cap_str)
                pool_usage = float(usage_str)
                found = True
            break

    if not found:
        return {"changed": False, "msg": "pool not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used_percent = (pool_usage / pool_capacity * 100.0) if pool_capacity > 0 else 0.0

    # Apply filesystem levels (Checkmk df defaults)
    warn = 80.0
    crit = 90.0
    levels = params.get("levels", None)
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        warn = float(levels[0]) if str(levels[0]).replace(".", "").replace("-", "").isdigit() else 80.0
        crit = float(levels[1]) if str(levels[1]).replace(".", "").replace("-", "").isdigit() else 90.0
    elif levels != None and type(levels) == "list" and len(levels) == 2:
        warn = float(levels[0])
        crit = float(levels[1])

    state = "OK"
    msg = ""
    if used_percent >= crit:
        state = "CRIT"
        msg = "Size: %f GB, %f%% used (>= %f%% CRIT)" % (pool_capacity / 1024.0 / 1024.0 / 1024.0,
                                                                used_percent, crit)
    elif used_percent >= warn:
        state = "WARN"
        msg = "Size: %f GB, %f%% used (>= %f%% WARN)" % (pool_capacity / 1024.0 / 1024.0 / 1024.0,
                                                                used_percent, warn)
    else:
        msg = "Size: %f GB, %f%% used" % (pool_capacity / 1024.0 / 1024.0 / 1024.0, used_percent)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"used_percent": used_percent},
                     "details": ""}}