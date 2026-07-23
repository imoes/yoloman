def main(ctx, params):
    # SNMP OIDs from the Checkmk plugin
    base_oid = ".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1"
    temp_oid = base_oid + ".2.190"   # temperature value (1/10 degree C)
    name_oid = base_oid + ".6.190"   # item name

    # Discovery mode: enumerate all temperature sensors
    if params.get("_discover"):
        # Walk both OIDs to get temperature and name pairs
        temp_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), temp_oid], mutates=False)
        name_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), name_oid], mutates=False)

        # Parse snmpwalk output: "OID = TYPE: value"
        temp_items = _parse_snmpwalk(temp_res.stdout)
        name_items = _parse_snmpwalk(name_res.stdout)

        # Match items by index (last number in OID)
        discovered = []
        for oid_name, name_val in name_items.items():
            idx = oid_name.rsplit(".", 1)[-1]
            temp_oid_full = base_oid + ".2." + idx
            name_oid_full = base_oid + ".6." + idx

            if temp_oid_full in temp_items and name_oid_full in name_items:
                temp_val = temp_items[temp_oid_full]
                item_name = name_items[name_oid_full].strip('"')
                # Validate temperature is numeric
                # Guard instead of try/except
                if temp_val.isdigit() or (temp_val.count('.') == 1 and temp_val.replace('.','').isdigit()):
                    temp_float = float(temp_val) / 10.0
                    discovered.append({
                        "item": item_name,
                        "params": {"levels": (70.0, 80.0)},
                        "metrics": ["temp"]
                    })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode: verify one item's temperature
    item = params.get("item", "")
    # Get temperature and name for this item by walking and filtering
    temp_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), base_oid], mutates=False)

    # Parse entire walk and find the item
    parsed = _parse_snmpwalk(temp_res.stdout)
    temp = None
    for oid, val in parsed.items():
        if oid.endswith(".6.190"):
            # This is a name OID; extract base index
            idx = oid.rsplit(".", 2)[-2]
            temp_oid = base_oid + ".2." + idx
            name_oid = oid
            if name_oid in parsed and temp_oid in parsed:
                name = parsed[name_oid].strip('"')
                if name == item:
                    temp_val = parsed[temp_oid]
                    if temp_val.isdigit() or (temp_val.count('.') == 1 and temp_val.replace('.','').isdigit()):
                        temp = float(temp_val) / 10.0
                    break

    # If item not found, return UNKNOWN
    if temp == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get temperature thresholds
    warn = params.get("levels", (70.0, 80.0))
    if type(warn) == "list":
        warn_high = warn[0]
        crit_high = warn[1]
    else:
        warn_high = 70.0
        crit_high = 80.0

    # Determine state
    if crit_high != None and temp >= crit_high:
        state = "CRIT"
    elif warn_high != None and temp >= warn_high:
        state = "WARN"
    else:
        state = "OK"

    # Build message
    msg = "Temperature: %f C" % temp

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": ""
        }
    }


def _parse_snmpwalk(output):
    result = {}
    for line in output.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) == 2:
            oid = parts[0].strip()
            val = parts[1].strip()
            # Strip type prefix (e.g., "INTEGER:", "STRING:", "Gauge32:")
            if ":" in val:
                val = val.split(":", 1)[1].strip()
            result[oid] = val
    return result