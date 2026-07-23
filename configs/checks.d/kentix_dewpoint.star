# Sensor item names based on the Checkmk plugin's parsing logic
SENSOR_ITEMS = ["LAN", "Rack"]

def _get_dewpoint_data(ctx):
    host = ctx.facts().get("hostname", "localhost")
    community = "public"
    base_oid = ".1.3.6.1.4.1.37954"
    # Fetch both OIDs: LAN (2.1.3.1) and Rack (3.1.2.1)
    oids = ["2.1.3.1", "3.1.2.1"]
    data = {}
    for i, oid_suffix in enumerate(oids):
        oid = base_oid + "." + oid_suffix
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        if res.rc != 0:
            continue
        line = res.stdout.strip()
        # Parse: OID = STRING: "value" or OID = INTEGER: value
        if " = " not in line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        value_str = parts[1].strip()
        # Handle different SNMP value types
        if value_str.startswith("STRING: "):
            value_str = value_str[8:].strip('"')
        elif value_str.startswith("INTEGER: "):
            value_str = value_str[9:]
        # Extract numeric value (remove trailing units if any)
        # e.g., "123" or "123.4"
        if value_str == "":
            continue
        val = float(value_str) if value_str.replace('.', '').lstrip('-').isdigit() else None
        if val != None:
            data[SENSOR_ITEMS[i]] = val / 10.0
    return data

def _parse_dewpoint_data(ctx):
    data = _get_dewpoint_data(ctx)
    # Return dict of {item: reading} only if at least one sensor is present
    return data if data else None

def main(ctx, params):
    if params.get("_discover"):
        section = _parse_dewpoint_data(ctx)
        if section == None or not section:
            return {"changed": False, "msg": "discovered 0 dewpoint sensors",
                    "data": {"discovery": []}}
        discovery = []
        for item in section:
            # Checkmk defaults are empty dict; temperature check defaults used below
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["temperature"]
            })
        return {"changed": False, "msg": "discovered %d dewpoint sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _parse_dewpoint_data(ctx)
    if section == None or item not in section:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = section[item]
    # Checkmk temperature check defaults
    # For dewpoint, we treat reading as temperature value in °C
    # Default thresholds from Checkmk temperature ruleset
    warn = params.get("levels", (20.0, 30.0))
    warn_upper, crit_upper = warn if isinstance(warn, tuple) else (None, None)
    warn_lower, crit_lower = params.get("levels_lower", (None, None))
    warn_upper = warn_upper if warn_upper != None else 20.0
    crit_upper = crit_upper if crit_upper != None else 30.0
    warn_lower = warn_lower if warn_lower != None else None
    crit_lower = crit_lower if crit_lower != None else None

    # Determine state
    state = "OK"
    details = ""

    # Upper levels
    if crit_upper != None and reading >= crit_upper:
        state = "CRIT"
    elif warn_upper != None and reading >= warn_upper:
        state = "WARN"

    # Lower levels (only if defined)
    if crit_lower != None and reading <= crit_lower:
        state = "CRIT"
    elif warn_lower != None and reading <= warn_lower:
        state = "WARN"

    # Build message
    msg = "Dewpoint: %f C" % reading

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}