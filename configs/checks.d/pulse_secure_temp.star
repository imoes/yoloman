def main(ctx, params):
    # discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.12532.42"],
            mutates=False,
        )
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []},
            }

        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Format: .1.3.6.1.4.1.12532.42.1 = INTEGER: 45
            parts = line.strip().split("=")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract last number in OID (e.g., "1" from ".1.3.6.1.4.1.12532.42.1")
            oid_tokens = oid_part.split(".")
            if len(oid_tokens) < 2:
                continue
            item = oid_tokens[-1]
            # Check if value is parseable as integer
            if value_part.startswith("INTEGER:"):
                val_str = value_part.split(":")[1].strip()
                if val_str.lstrip("-").isdigit():
                    items.append({"item": item, "params": {"levels": (70.0, 75.0)}, "metrics": ["temp"]})

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items},
        }

    # check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.12532.42." + item],
        mutates=False,
    )

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    line = res.stdout.strip()
    if not line:
        return {
            "changed": False,
            "msg": "empty response for sensor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Format: .1.3.6.1.4.1.12532.42.1 = INTEGER: 45
    parts = line.split("=")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "unable to parse response for sensor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value_part = parts[1].strip()
    if not value_part.startswith("INTEGER:"):
        return {
            "changed": False,
            "msg": "unexpected value format for sensor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    val_str = value_part.split(":")[1].strip()
    if not val_str.lstrip("-").isdigit():
        return {
            "changed": False,
            "msg": "invalid integer value for sensor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reading = float(val_str)

    # Apply temperature levels
    levels = params.get("levels", (70.0, 75.0))
    warn = levels[0] if isinstance(levels, list) and len(levels) >= 2 else 70.0
    crit = levels[1] if isinstance(levels, list) and len(levels) >= 2 else 75.0

    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Temperature: %f C" % reading

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": reading},
            "details": "",
        },
    }