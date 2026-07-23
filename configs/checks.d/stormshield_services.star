def main(ctx, params):
    # SNMP base OID for stormshield services
    base_oid = ".1.3.6.1.4.1.11256.1.7.1.1"
    # Service OID components
    name_oid_suffix = ".2"
    state_oid_suffix = ".3"
    uptime_oid_suffix = ".4"

    # Discover services in discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid + name_oid_suffix
        ], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            if line.find("=") == -1:
                continue
            oid_part, value_part = line.split("=", 1)
            value = value_part.strip()
            if value.startswith("STRING: "):
                name = value[8:].strip('"')
                # Check state is "up" (1) by doing a second probe
                state_oid = base_oid + state_oid_suffix + oid_part.rsplit(".", 1)[1]
                state_res = ctx.run([
                    "snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-On", params.get("host", "localhost"), state_oid
                ], mutates=False)
                for state_line in state_res.stdout.splitlines():
                    if state_line.find("=") == -1:
                        continue
                    _, state_value_part = state_line.split("=", 1)
                    state_val = state_value_part.strip()
                    if state_val.isdigit() and state_val == "1":
                        items.append({
                            "item": name,
                            "params": {},
                            "metrics": ["uptime"]
                        })
                        break

        return {
            "changed": False,
            "msg": "discovered %d services" % len(items),
            "data": {"discovery": items}
        }

    # Normal check mode: inspect one item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get service state
    # First find the correct instance OID suffix for the item name
    name_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base_oid + name_oid_suffix
    ], mutates=False)

    # Look for the exact match in the name walk output
    instance_suffix = ""
    for line in name_res.stdout.splitlines():
        if line.find("=") == -1:
            continue
        oid_part, value_part = line.split("=", 1)
        value = value_part.strip()
        if value.startswith("STRING: "):
            name = value[8:].strip('"')
            if name == item:
                # Extract the instance suffix from the OID
                instance_suffix = oid_part.strip().rsplit(".", 1)[1]
                break

    if instance_suffix == "":
        return {
            "changed": False,
            "msg": "service not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Now fetch state and uptime for this instance
    state_oid = base_oid + state_oid_suffix + "." + instance_suffix
    uptime_oid = base_oid + uptime_oid_suffix + "." + instance_suffix

    state_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), state_oid
    ], mutates=False)
    uptime_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), uptime_oid
    ], mutates=False)

    state_val = ""
    uptime_val = 0

    # Parse state
    for line in state_res.stdout.splitlines():
        if line.find("=") == -1:
            continue
        _, value_part = line.split("=", 1)
        state_val = value_part.strip()
        break

    # Parse uptime
    for line in uptime_res.stdout.splitlines():
        if line.find("=") == -1:
            continue
        _, value_part = line.split("=", 1)
        uptime_str = value_part.strip()
        # Try to parse as integer
        if uptime_str.isdigit():
            uptime_val = int(uptime_str)
        break

    # Determine state
    state_label = "up" if state_val.isdigit() and state_val == "1" else "down"
    checkmk_state = "CRIT" if state_label == "down" else "OK"

    metrics = {}
    if state_label == "up":
        metrics = {"uptime": uptime_val}

    # Build message
    msg = state_label.title() + (" " + item if state_label == "down" else "")
    details = ""
    if state_label == "up":
        # Format uptime like Checkmk's render.timespan
        days = uptime_val // 86400
        hours = (uptime_val % 86400) // 3600
        minutes = (uptime_val % 3600) // 60
        seconds = uptime_val % 60
        parts = []
        if days > 0:
            parts.append("%d day%s" % (days, "s" if days != 1 else ""))
        if hours > 0 or days > 0:
            parts.append("%d hour%s" % (hours, "s" if hours != 1 else ""))
        parts.append("%d minute%s" % (minutes, "s" if minutes != 1 else ""))
        parts.append("%d second%s" % (seconds, "s" if seconds != 1 else ""))
        uptime_str = ", ".join(parts)
        msg = "up, Uptime: " + uptime_str

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": checkmk_state,
            "metrics": metrics,
            "details": details
        }
    }