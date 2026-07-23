# Starlark module: checkmk.liebert_cooling_status
# Read-only check for Liebert cooling status via SNMP

def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    # OID 10.1.2.1.5302 -> Status Name
    # OID 20.1.2.1.5302 -> Status Value
    name_oid = base_oid + ".10.1.2.1.5302"
    value_oid = base_oid + ".20.1.2.1.5302"

    # Discovery mode
    if params.get("_discover"):
        # Fetch name and value pairs
        name_res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), name_oid
        ], mutates=False)
        value_res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), value_oid
        ], mutates=False)

        # Parse name and value OIDs into a dict
        name_map = {}
        for line in name_res.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract the numeric suffix from the OID (e.g., .1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.1.5302.1.1 -> suffix "1")
            suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else ""
            # Extract the name (value after '=')
            name = value_part.strip('"') if value_part.startswith('"') and value_part.endswith('"') else value_part
            name_map[suffix] = name

        value_map = {}
        for line in value_res.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else ""
            value = value_part.strip('"') if value_part.startswith('"') and value_part.endswith('"') else value_part
            value_map[suffix] = value

        # Build discovery list: item = status name, params empty (no thresholds), metrics empty
        items = []
        for suffix, name in name_map.items():
            if suffix != "" and suffix in value_map:
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d cooling status items" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required for check mode",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch name and value lists
    name_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), name_oid
    ], mutates=False)
    value_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), value_oid
    ], mutates=False)

    # Parse OIDs into mapping
    name_map = {}
    for line in name_res.stdout.splitlines():
        if line.strip() == "":
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else ""
        name = value_part.strip('"') if value_part.startswith('"') and value_part.endswith('"') else value_part
        name_map[suffix] = name

    value_map = {}
    for line in value_res.stdout.splitlines():
        if line.strip() == "":
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else ""
        value = value_part.strip('"') if value_part.startswith('"') and value_part.endswith('"') else value_part
        value_map[suffix] = value

    # Find matching item
    found = False
    for suffix, name in name_map.items():
        if name == item and suffix in value_map:
            found = True
            status = value_map[suffix]
            # Checkmk returns OK regardless of the actual status string
            return {
                "changed": False,
                "msg": status,
                "data": {"state": "OK", "metrics": {}, "details": ""}
            }

    # Item not found
    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }