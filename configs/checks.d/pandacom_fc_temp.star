def main(ctx, params):
    warn_default, crit_default = 35.0, 40.0

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.3652.3.3.3.1.1.2"
        ], mutates=False)

        slots = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if len(stripped) == 0:
                continue
            parts = stripped.split(" = ")
            if len(parts) != 2:
                continue
            value_part = parts[1].strip()
            if value_part.startswith("INTEGER: "):
                slot_str = value_part[9:]
                if slot_str.isdigit():
                    slots.append(int(slot_str))

        items = []
        for slot in slots:
            item_name = str(slot)
            items.append({
                "item": item_name,
                "params": {"levels": (warn_default, crit_default)},
                "metrics": ["temperature"]
            })

        return {
            "changed": False,
            "msg": "discovered %d FC modules" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    warn_user = params.get("levels", (warn_default, crit_default))
    warn_val = warn_user[0] if len(warn_user) >= 1 else warn_default
    crit_val = warn_user[1] if len(warn_user) >= 2 else crit_default

    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.3652.3.3.3"
    ], mutates=False)

    data = {}

    for line in res.stdout.splitlines():
        stripped = line.strip()
        if len(stripped) == 0:
            continue

        parts = stripped.split(" = ")
        if len(parts) != 2:
            continue

        oid_full = parts[0].strip()
        value_part = parts[1].strip()

        base = ".1.3.6.1.4.1.3652.3.3.3"
        suffix = oid_full[len(base):]
        if len(suffix) == 0 or suffix[0] != '.':
            continue
        suffix = suffix[1:]
        suffix_parts = suffix.split(".")
        if len(suffix_parts) != 3:
            continue

        section = suffix_parts[0]
        oid_type = suffix_parts[1]
        slot = suffix_parts[2]

        value_str = value_part
        if value_part.startswith("INTEGER: "):
            value_str = value_part[9:]

        if not section in ["1.1", "2.1.13", "2.1.14"]:
            continue

        if not value_str.isdigit():
            continue
        val = int(value_str)

        if slot not in data:
            data[slot] = {"temp": None, "warn": None, "crit": None}

        if section == "1.1" and oid_type == "7":
            data[slot]["temp"] = val / 10.0
        elif section == "2.1" and oid_type == "13":
            data[slot]["warn"] = val
        elif section == "2.1" and oid_type == "14":
            data[slot]["crit"] = val

    if item not in data or data[item]["temp"] == None:
        return {
            "changed": False,
            "msg": "FC module %s not found or no temperature data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    temp = data[item]["temp"]
    slot_warn = data[item]["warn"]
    slot_crit = data[item]["crit"]

    dev_levels = None
    if slot_warn != None and slot_crit != None:
        dev_levels = (float(slot_warn), float(slot_crit))

    state = "OK"
    if dev_levels != None:
        if temp >= dev_levels[1]:
            state = "CRIT"
        elif temp >= dev_levels[0]:
            state = "WARN"
    else:
        if temp >= crit_val:
            state = "CRIT"
        elif temp >= warn_val:
            state = "WARN"

    details = ""
    if dev_levels != None:
        details = "Device levels: %f/%f" % (dev_levels[0], dev_levels[1])

    return {
        "changed": False,
        "msg": "Temperature: %f C" % temp,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": details
        }
    }