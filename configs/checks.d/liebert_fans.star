def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)

    item = params.get("item", "")
    warn_lower, crit_lower = params.get("levels_lower", (None, None))
    warn_upper, crit_upper = params.get("levels", (80.0, 90.0))

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    ], mutates=False)

    lines = res.stdout.splitlines()
    parsed = {}
    last_name = ""

    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_str = parts[1].strip()

        base_prefix = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        if not oid_full.startswith(base_prefix + "."):
            continue
        suffix = oid_full[len(base_prefix):]

        if suffix.startswith(".10.1.2.1.5077"):
            if value_str.startswith('"') and value_str.endswith('"'):
                name = value_str[1:-1]
            else:
                name = value_str
            last_name = name
            if last_name not in parsed:
                parsed[last_name] = (0.0, "")
        elif suffix.startswith(".20.1.2.1.5077"):
            val = 0.0
            if value_str != "":
                # Guard instead of try: only convert if looks like float
                # Remove non-numeric chars (., -, +) and check remaining digits
                temp = value_str.replace(".", "").replace("-", "").replace("+", "")
                if temp.isdigit() or (temp == "" and value_str.replace(".", "").replace("-", "").replace("+", "") == "."):
                    val = float(value_str)
                elif value_str.replace(".", "").replace("-", "").replace("+", "").isdigit():
                    val = float(value_str)
            if last_name in parsed:
                current = parsed[last_name]
                parsed[last_name] = (val, current[1])
        elif suffix.startswith(".30.1.2.1.5077"):
            if value_str.startswith('"') and value_str.endswith('"'):
                unit = value_str[1:-1]
            else:
                unit = value_str
            if last_name in parsed:
                current = parsed[last_name]
                parsed[last_name] = (current[0], unit)

    if item not in parsed:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value, unit = parsed[item]

    state = "OK"
    msg_parts = []
    msg_parts.append("Speed: %f %s" % (value, unit))

    if crit_upper != None and value >= crit_upper:
        state = "CRIT"
        msg_parts.append("(crit at %f%%)" % crit_upper)
    elif warn_upper != None and value >= warn_upper:
        state = "WARN"
        msg_parts.append("(warn at %f%%)" % warn_upper)

    if crit_lower != None and value <= crit_lower:
        state = "CRIT"
        msg_parts.append("(crit at %f%%)" % crit_lower)
    elif warn_lower != None and value <= warn_lower:
        state = "WARN"
        msg_parts.append("(warn at %f%%)" % warn_lower)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"fan_perc": value},
            "details": ""
        }
    }


def _discover(ctx, params):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    ], mutates=False)

    lines = res.stdout.splitlines()
    items = []
    last_name = ""

    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_str = parts[1].strip()

        base_prefix = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        if not oid_full.startswith(base_prefix + "."):
            continue
        suffix = oid_full[len(base_prefix):]

        if suffix.startswith(".10.1.2.1.5077"):
            if value_str.startswith('"') and value_str.endswith('"'):
                name = value_str[1:-1]
            else:
                name = value_str
            if name != "":
                items.append(name)

    discovery = []
    for item in items:
        discovery.append({
            "item": item,
            "params": {"levels": (80.0, 90.0)},
            "metrics": ["fan_perc"]
        })

    return {
        "changed": False,
        "msg": "discovered %d fans" % len(discovery),
        "data": {"discovery": discovery}
    }