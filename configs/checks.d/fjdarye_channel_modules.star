def main(ctx, params):
    # Discover mode: enumerate channel modules and their metrics
    if params.get("_discover"):
        # Determine base OIDs from supported device OIDs
        base_oids = [
            ".1.3.6.1.4.1.211.1.21.1.60",
            ".1.3.6.1.4.1.211.1.21.1.100",
            ".1.3.6.1.4.1.211.1.21.1.101",
            ".1.3.6.1.4.1.211.1.21.1.150",
            ".1.3.6.1.4.1.211.1.21.1.153",
        ]
        items = []
        for base_oid in base_oids:
            # Each device uses SNMPTree(base=base_oid + ".2.1.2.1", oids=["1", "3"])
            oid_base = base_oid + ".2.1.2.1"
            res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), oid_base], mutates=False)
            # Parse snmpwalk output: "<oid>.<index> = INTEGER: <value>" lines
            lines = res.stdout.splitlines()
            for line in lines:
                # Format: oid.index = INTEGER: value OR oid.index = <type>: value
                if "=" not in line:
                    continue
                parts = line.split("=", 1)
                if len(parts) != 2:
                    continue
                oid_full = parts[0].strip()
                value_part = parts[1].strip()
                # Extract last numeric component after final dot as index
                if "." in oid_full:
                    idx_str = oid_full.rsplit(".", 1)[-1]
                    # Parse value
                    status = ""
                    if ":" in value_part:
                        status = value_part.split(":", 1)[1].strip()
                        # Remove trailing spaces/quotes if present
                        status = status.strip().rstrip('"').lstrip('"')
                    # Only include items with non-invalid status
                    if status and status != "4":
                        items.append({
                            "item": idx_str,
                            "params": {},
                            "metrics": []
                        })
        return {
            "changed": False,
            "msg": "discovered %d channel modules" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: examine one specific channel module
    item = params.get("item", "")
    # Use the same discovery base OIDs to locate the item
    base_oids = [
        ".1.3.6.1.4.1.211.1.21.1.60",
        ".1.3.6.1.4.1.211.1.21.1.100",
        ".1.3.6.1.4.1.211.1.21.1.101",
        ".1.3.6.1.4.1.211.1.21.1.150",
        ".1.3.6.1.4.1.211.1.21.1.153",
    ]
    status = ""
    for base_oid in base_oids:
        oid_base = base_oid + ".2.1.2.1"
        # snmpget only for the specific instance
        oid_instance = oid_base + "." + item
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), oid_instance], mutates=False)
        # Parse snmpget output: "<oid> = <type>: <value>"
        lines = res.stdout.splitlines()
        for line in lines:
            if "=" in line:
                value_part = line.split("=", 1)[1].strip()
                if ":" in value_part:
                    status = value_part.split(":", 1)[1].strip()
                    # Remove trailing spaces/quotes if present
                    status = status.strip().rstrip('"').lstrip('"')
        # If we got a value, break early
        if status:
            break

    # Map status codes to Checkmk states and messages
    FJDARYE_ITEM_STATUS = {
        "1": ("OK", "Normal"),
        "2": ("CRIT", "Alarm"),
        "3": ("WARN", "Warning"),
        "4": ("CRIT", "Invalid"),
        "5": ("CRIT", "Maintenance"),
        "6": ("CRIT", "Undefined"),
    }

    if not status:
        return {
            "changed": False,
            "msg": "no such channel module: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state_str, summary = FJDARYE_ITEM_STATUS.get(status, ("UNKNOWN", "Unknown"))
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }
