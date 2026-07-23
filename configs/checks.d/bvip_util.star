# Module-level constants (no imports allowed)
ITEM_INDEX = {
    "Total": 0,
    "Coder": 1,
    "VCA": 2,
}

# Discovery defaults
DEFAULT_PARAMS = {"levels": (90.0, 95.0)}


def main(ctx, params):
    # Discovery mode: enumerate items and their metrics
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.3967.1.1.9.1"
        ], mutates=False)
        # Check if SNMP walk returned data (at least 3 OIDs expected)
        lines = res.stdout.splitlines() if res.stdout else []
        if len(lines) < 3:
            return {"changed": False, "msg": "no CPU data found", "data": {"discovery": []}}
        # All three items exist if SNMP data is present
        discovery = []
        for name in ["Total", "Coder", "VCA"]:
            discovery.append({
                "item": name,
                "params": {
                    "warn": DEFAULT_PARAMS["levels"][0],
                    "crit": DEFAULT_PARAMS["levels"][1]
                },
                "metrics": ["util"]
            })
        return {"changed": False, "msg": "discovered %d CPU items" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: validate one item
    item = params.get("item", "")
    warn, crit = params.get("levels", DEFAULT_PARAMS["levels"])
    # Map item to index and fetch usage from SNMP
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.3967.1.1.9.1"
    ], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    if len(lines) < 3:
        return {"changed": False, "msg": "SNMP data missing for CPU utilization",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Parse SNMP output: format is "OID = INTEGER: value"
    values = []
    for line in lines:
        # Extract value after ": "
        idx = line.find(": ")
        if idx >= 0:
            val_str = line[idx + 2:].strip()
            # Guard: only convert if it's a valid integer string
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                values.append(int(val_str))
            else:
                return {"changed": False, "msg": "invalid SNMP value format",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        else:
            return {"changed": False, "msg": "invalid SNMP line format",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if len(values) < 3:
        return {"changed": False, "msg": "insufficient CPU values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Get usage for requested item
    if item not in ITEM_INDEX:
        return {"changed": False, "msg": "unknown CPU item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    usage = values[ITEM_INDEX[item]]
    # For "Total", report idle percentage (100 - active)
    if item == "Total":
        usage = 100 - usage
    # Determine state (check CPU utilization: upper levels)
    if usage >= crit:
        state = "CRIT"
    elif usage >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {
        "changed": False,
        "msg": "%s: %d%%" % (item, usage),
        "data": {
            "state": state,
            "metrics": {"util": float(usage)},
            "details": "",
        },
    }
