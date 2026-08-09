# Mapping of PSU status codes to (state, summary)
_PSU_STATE_MAP = {
    "1": ("CRIT", "Not present"),
    "2": ("CRIT", "Not plugged"),
    "3": ("OK", "Powered"),
    "4": ("WARN", "Failed"),
    "5": ("CRIT", "Permanent Failure"),
    "6": ("UNKNOWN", "Max"),
    "8": ("CRIT", "Unplugged"),
    "9": ("CRIT", "Aux not powered"),
}

# SNMP base OID for the PSU table
_BASE_OID = ".1.3.6.1.4.1.11.2.14.11.5.1.1.1"
# Column OIDs (relative to base)
_COL_STATUS = _BASE_OID + ".2"
_COL_TEMP = _BASE_OID + ".4"

def _walk_psu_table(ctx, params):
    """Walk the SNMP table and return a dict mapping index -> {temp, status}."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Walk the status column to get all indices and their status values
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _COL_STATUS],
        mutates=False
    )
    if res.rc != 0:
        return None

    items = {}
    for line in res.stdout.splitlines():
        # Each line: "<OID> <value>", split on first space
        idx = line.find(" ")
        if idx < 0:
            continue
        oid = line[:idx]
        value = line[idx + 1:].strip().strip('"')

        # Extract the index from the OID suffix
        suffix = oid[len(_COL_STATUS) + 1:]
        if not suffix:
            continue

        # Strip surrounding quotes from value if present
        status_val = value.strip('"') if value.startswith('"') and value.endswith('"') else value

        items[suffix] = {"status": status_val, "temp": 0}

    if not items:
        return None

    # Now fetch the temperature column for each index
    for index in items:
        get_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, _COL_TEMP + "." + index],
            mutates=False
        )
        if get_res.rc == 0:
            temp_str = get_res.stdout.strip().strip('"')
            if temp_str and temp_str != "0":
                items[index]["temp"] = int(temp_str) if temp_str.lstrip("-").isdigit() else 0

    return items


def main(ctx, params):
    if params.get("_discover"):
        section = _walk_psu_table(ctx, params)
        if section == None or len(section) == 0:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }

        # Discover temperature services for each PSU index
        discovery = []
        for index in section:
            discovery.append({
                "item": index,
                "params": {"levels": (70.0, 80.0)},
                "metrics": ["temperature"],
            })

        return {
            "changed": False,
            "msg": "discovered %d temperature items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    section = _walk_psu_table(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "no SNMP data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if item not in section:
        return {
            "changed": False,
            "msg": "no such power supply: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = section[item]
    status = data["status"]
    temp = data["temp"]

    # Determine state from status code
    mapped = _PSU_STATE_MAP.get(status)
    if mapped == None:
        state = "UNKNOWN"
        summary = "Unknown status code sent by device"
    else:
        state = mapped[0]
        summary = mapped[1]

    # Build metric: temperature value (use 0 if not available)
    metrics = {}
    if temp > 0:
        metrics["temperature"] = temp

    # Apply temperature thresholds if in OK/WARN state
    warn = params.get("warn", 70)
    crit = params.get("crit", 80)
    if temp > 0 and (state == "OK" or state == "UNKNOWN"):
        if temp >= crit:
            state = "CRIT"
            summary = "Temperature: %d°C (critical)" % temp
        elif temp >= warn:
            state = "WARN"
            summary = "Temperature: %d°C (warning)" % temp
        else:
            summary = "Temperature: %d°C" % temp

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }