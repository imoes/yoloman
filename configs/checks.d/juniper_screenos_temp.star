# Top-level constants (required by Starlark contract)
DEFAULT_LEVELS = (70.0, 80.0)
JUNIPER_SCREENOS_OID_BASE = ".1.3.6.1.4.1.3224.21.4.1"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            JUNIPER_SCREENOS_OID_BASE + ".4",  # Temperature names (OID 4)
            JUNIPER_SCREENOS_OID_BASE + ".3",  # Temperature values (OID 3)
        ], mutates=False)
        if res.rc != 0:
            # Host unreachable or SNMP error -> no discovery
            return {"changed": False, "msg": "discovered 0 sensors",
                    "data": {"discovery": []}}
        # Parse snmpwalk output: each line is "OID = STRING: value"
        lines = res.stdout.splitlines()
        names = []
        temps = []
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 2)
            if len(parts) < 2:
                continue
            oid_part, value_part = parts[0], parts[1]
            # Extract numeric OID suffix
            suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
            if oid_part.endswith(".4"):  # name OID
                names.append((suffix, value_part.strip('"')))
            elif oid_part.endswith(".3"):  # value OID
                temps.append((suffix, value_part))
        # Map name and temp by index (same order as walk)
        section = {}
        for i in range(min(len(names), len(temps))):
            suffix_name, name_str = names[i]
            suffix_temp, temp_str = temps[i]
            if suffix_name == suffix_temp:
                temp_val = 0
                if temp_str.isdigit() or (temp_str.startswith("-") and temp_str[1:].isdigit()):
                    temp_val = int(temp_str)
                # Clean name if ends with "Temperature"
                item = name_str
                if item.endswith("Temperature"):
                    item = item.rsplit(None, 1)[0]
                section[item] = temp_val
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": {"levels": DEFAULT_LEVELS},
                "metrics": ["temp"]
            })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode (not discovery)
    item = params.get("item", "")
    if item == None:
        item = ""

    # Fetch both OIDs in one walk
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        JUNIPER_SCREENOS_OID_BASE + ".4",  # name
        JUNIPER_SCREENOS_OID_BASE + ".3",  # value
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse and build section
    lines = res.stdout.splitlines()
    section = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 2)
        if len(parts) < 2:
            continue
        oid_part, value_part = parts[0], parts[1]
        suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
        if oid_part.endswith(".4"):
            name = value_part.strip('"')
            if name.endswith("Temperature"):
                name = name.rsplit(None, 1)[0]
            section[suffix] = {"name": name}
        elif oid_part.endswith(".3"):
            temp_val = 0
            if value_part.isdigit() or (value_part.startswith("-") and value_part[1:].isdigit()):
                temp_val = int(value_part)
            section[suffix]["temp"] = temp_val

    # Match item
    found_temp = None
    for suffix, entry in section.items():
        item_name = entry.get("name", "")
        if item_name == item:
            if "temp" in entry:
                found_temp = entry["temp"]
            break

    if found_temp == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply thresholds
    levels = params.get("levels", DEFAULT_LEVELS)
    warn = levels[0] if isinstance(levels, list) else levels.get("warn")
    crit = levels[1] if isinstance(levels, list) else levels.get("crit")
    if warn == None:
        warn = DEFAULT_LEVELS[0]
    if crit == None:
        crit = DEFAULT_LEVELS[1]

    temp_val = float(found_temp)
    if temp_val >= crit:
        state = "CRIT"
    elif temp_val >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "%s: %f C" % (item, temp_val),
        "data": {
            "state": state,
            "metrics": {"temp": temp_val},
            "details": ""
        }
    }