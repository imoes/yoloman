def main(ctx, params):
    if params.get("_discover"):
        # Discovery: fetch CPU entries and entity mapping from SNMP
        # First tree: cpmCPUTotal5minRev (OID base .1.3.6.1.4.1.9.9.109.1.1.1.1)
        res_cpu = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.109.1.1.1.1.2",
            ".1.3.6.1.4.1.9.9.109.1.1.1.1.8"
        ], mutates=False)
        if res_cpu.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed for CPU utilization data",
                "data": {"discovery": []}
            }

        # Second tree: entPhysicalName and entPhysicalClass
        res_entity = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.47.1.1.1.1.7",
            ".1.3.6.1.2.1.47.1.1.1.1.5"
        ], mutates=False)
        if res_entity.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed for entity data",
                "data": {"discovery": []}
            }

        # Parse CPU section (cpmCPUTotal5minRev)
        cpu_data = {}
        for line in res_cpu.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            value = value_part.split(": ", 1)[1].strip()
            if ".1.3.6.1.4.1.9.9.109.1.1.1.1.8." in oid_full:
                idx_str = oid_full.rsplit(".", 1)[-1]
                if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                    cpu_data[idx_str] = float(value)

        # Parse entity section
        entity_data = {}
        for line in res_entity.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            value = value_part.split(": ", 1)[1].strip()
            if ".1.3.6.1.2.1.47.1.1.1.1.7." in oid_full:
                idx_str = oid_full.rsplit(".", 1)[-1]
                desc = value.strip()
                if desc.lower().startswith("cpu "):
                    desc = desc[4:]
                entity_data[idx_str] = (desc, None)
            elif ".1.3.6.1.2.1.47.1.1.1.1.5." in oid_full:
                idx_str = oid_full.rsplit(".", 1)[-1]
                class_idx = int(value) if value.isdigit() else -1
                phys_class = parse_cisco_physical_class(class_idx)
                if idx_str in entity_data:
                    desc, _ = entity_data[idx_str]
                    entity_data[idx_str] = (desc, phys_class)

        # Get mapping cpu_id -> physical index
        res_cpu_idx = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.109.1.1.1.1.2"
        ], mutates=False)
        cpu_to_idx = {}
        if res_cpu_idx.rc == 0:
            for line in res_cpu_idx.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.strip().split(" = ")
                if len(parts) != 2:
                    continue
                oid_full, value_part = parts
                value = value_part.split(": ", 1)[1].strip()
                if ".1.3.6.1.4.1.9.9.109.1.1.1.1.2." in oid_full:
                    idx_str = oid_full.rsplit(".", 1)[-1]
                    cpu_to_idx[idx_str] = value.strip()

        parsed = {}
        for cpu_id, util in cpu_data.items():
            idx = cpu_to_idx.get(cpu_id, cpu_id)
            desc, phys_class = entity_data.get(idx, (cpu_id, None))
            if phys_class == "fan" or phys_class == "sensor":
                continue
            parsed[desc] = util

        # Compute average
        if parsed:
            vals = []
            for v in parsed.values():
                if type(v) == "int" or type(v) == "float":
                    vals.append(v)
            if len(vals) > 0:
                total = 0
                for x in vals:
                    total = total + x
                parsed["average"] = total / len(vals)

        # Build discovery result
        discovery_params = {"individual": params.get("individual", True), "average": params.get("average", False)}
        out = []
        for item in parsed:
            if item and item != "average" and discovery_params["individual"]:
                out.append({"item": item, "params": {"levels": (80.0, 90.0)}, "metrics": ["cpu_util"]})
            elif item == "average" and discovery_params["average"]:
                out.append({"item": item, "params": {"levels": (80.0, 90.0)}, "metrics": ["cpu_util"]})

        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}
        }

    # Check mode
    item = params.get("item", "")
    res_cpu = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.109.1.1.1.1.2",
        ".1.3.6.1.4.1.9.9.109.1.1.1.1.8"
    ], mutates=False)
    if res_cpu.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    cpu_data = {}
    for line in res_cpu.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        value = value_part.split(": ", 1)[1].strip()
        if ".1.3.6.1.4.1.9.9.109.1.1.1.1.8." in oid_full:
            idx_str = oid_full.rsplit(".", 1)[-1]
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                cpu_data[idx_str] = float(value)

    res_entity = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.47.1.1.1.1.7",
        ".1.3.6.1.2.1.47.1.1.1.1.5"
    ], mutates=False)
    entity_data = {}
    if res_entity.rc == 0:
        for line in res_entity.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            value = value_part.split(": ", 1)[1].strip()
            if ".1.3.6.1.2.1.47.1.1.1.1.7." in oid_full:
                idx_str = oid_full.rsplit(".", 1)[-1]
                desc = value.strip()
                if desc.lower().startswith("cpu "):
                    desc = desc[4:]
                entity_data[idx_str] = (desc, None)
            elif ".1.3.6.1.2.1.47.1.1.1.1.5." in oid_full:
                idx_str = oid_full.rsplit(".", 1)[-1]
                class_idx = int(value) if value.isdigit() else -1
                phys_class = parse_cisco_physical_class(class_idx)
                if idx_str in entity_data:
                    desc, _ = entity_data[idx_str]
                    entity_data[idx_str] = (desc, phys_class)

    res_cpu_idx = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.109.1.1.1.1.2"
    ], mutates=False)
    cpu_to_idx = {}
    if res_cpu_idx.rc == 0:
        for line in res_cpu_idx.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            value = value_part.split(": ", 1)[1].strip()
            if ".1.3.6.1.4.1.9.9.109.1.1.1.1.2." in oid_full:
                idx_str = oid_full.rsplit(".", 1)[-1]
                cpu_to_idx[idx_str] = value.strip()

    parsed = {}
    for cpu_id, util in cpu_data.items():
        idx = cpu_to_idx.get(cpu_id, cpu_id)
        desc, phys_class = entity_data.get(idx, (cpu_id, None))
        if phys_class == "fan" or phys_class == "sensor":
            continue
        parsed[desc] = util

    util = None
    if item == "average":
        vals = []
        for v in parsed.values():
            if type(v) == "int" or type(v) == "float":
                vals.append(v)
        if len(vals) > 0:
            total = 0
            for x in vals:
                total = total + x
            util = total / len(vals)
    else:
        util = parsed.get(item)

    if util == None:
        return {
            "changed": False,
            "msg": "no CPU data found for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    warn = params.get("levels", (80.0, 90.0))
    warn_val = warn[0]
    crit_val = warn[1]

    state = "OK"
    if util >= crit_val:
        state = "CRIT"
    elif util >= warn_val:
        state = "WARN"

    msg = "CPU utilization: %f%%" % util
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"cpu_util": util}, "details": ""}
    }


def parse_cisco_physical_class(class_idx):
    mapping = {
        2: "chassis", 3: "backplane", 4: "container", 5: "powerUnit",
        6: "module", 7: "port", 8: "stack", 9: "cpu", 10: "disk",
        11: "fan", 12: "sensor"
    }
    return mapping.get(class_idx, "unknown")