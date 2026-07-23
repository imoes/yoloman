def main(ctx, params):
    # Map fan state codes to descriptions
    fan_states = {
        0: "has no status",
        1: "not running",
        2: "running",
    }

    # Discover mode: enumerate all fan items
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.11.1.2"
        # Try AOS7 OID first, fall back to classic AOS
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)

        # If AOS7 lookup fails, try classic OID
        if res.stdout == "" or res.stdout.find("No Such Instance") != -1 or res.stdout.find("No Such Object") != -1:
            base_oid = ".1.3.6.1.4.1.6486.800.1.1.1.3.1.1.11.1.2"
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), base_oid
            ], mutates=False)

        items = []
        # Parse snmpwalk output lines: "<oid> = INTEGER: <value>"
        for line in res.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            # Extract value from "OID = TYPE: value"
            parts = line.split(": ")
            if len(parts) >= 2 and parts[-1].isdigit():
                items.append({
                    "item": str(len(items) + 1),
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: verify one fan item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "fan item missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.11.1.2"
    # Try AOS7 OID first, fall back to classic AOS
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)

    # If AOS7 lookup fails, try classic OID
    if res.stdout == "" or res.stdout.find("No Such Instance") != -1 or res.stdout.find("No Such Object") != -1:
        base_oid = ".1.3.6.1.4.1.6486.800.1.1.1.3.1.1.11.1.2"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)

    # Parse snmpwalk output to find the fan state for this item index
    fan_state = None
    lines = res.stdout.splitlines()
    idx = int(item) if item.isdigit() else 0
    if idx >= 1 and idx <= len(lines):
        line = lines[idx - 1].strip()
        parts = line.split(": ")
        if len(parts) >= 2:
            value_str = parts[-1].strip()
            if value_str.isdigit():
                fan_state = int(value_str)

    # Determine state and summary
    if fan_state == None:
        return {
            "changed": False,
            "msg": "fan item %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    summary = "Fan " + fan_states.get(fan_state, "unknown (%s)" % fan_state)
    state = "OK" if fan_state == 2 else "CRIT"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
