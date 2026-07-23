# ===== module-level constants =====
# OID base for apc_symmetra_output section
_BASE_OID = ".1.3.6.1.4.1.318.1.1.1.4.2"
_OID_VOLTAGE = _BASE_OID + ".1.0"
_OID_CURRENT = _BASE_OID + ".4.0"
_OID_OUTPUT_LOAD = _BASE_OID + ".3.0"

# Default thresholds from Checkmk plugin
_DEFAULT_PARAMS = {"voltage": (220, 220)}


def _snmp_parse_line(line):
    """Parse an snmpwalk line like '.1.3.6.1.4.1.318.1.1.1.4.2.1.0 = INTEGER: 231'."""
    # Split on '=' and strip spaces
    parts = line.split("=", 1)
    if len(parts) != 2:
        return None, None
    oid_part = parts[0].strip()
    value_part = parts[1].strip()
    # Extract value: expect "INTEGER: 231", " Gauge32: 231", or just "231"
    if ":" in value_part:
        value_str = value_part.split(":", 1)[1].strip()
    else:
        value_str = value_part
    # Handle trailing units like '%'
    value_str = value_str.rstrip("%").strip()
    return oid_part, value_str


def _snmp_get_host_facts(ctx):
    """Return host facts needed for detection."""
    return ctx.facts()


def _is_apc_device(ctx):
    """Check if host is an APC device via sysObjectID."""
    # sysObjectID OID
    sysobjectid_oid = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.get("community", "public"),
                   "-On", ctx.get("host", "localhost"), sysobjectid_oid], mutates=False)
    if res.rc != 0:
        return False
    for line in res.stdout.splitlines():
        oid, value = _snmp_parse_line(line)
        if oid == sysobjectid_oid and value != None:
            # APC devices start with .1.3.6.1.4.1.318
            return value.startswith(".1.3.6.1.4.1.318")
    return False


def main(ctx, params):
    # Extract parameters with Checkmk defaults
    item = params.get("item", "")
    voltage_levels = params.get("voltage", _DEFAULT_PARAMS["voltage"])
    warn_voltage, crit_voltage = voltage_levels[0], voltage_levels[1]

    # Discovery mode: enumerate items
    if params.get("_discover"):
        if not _is_apc_device(ctx):
            return {"changed": False, "msg": "not an APC device",
                    "data": {"discovery": []}}

        # Fetch all three OIDs in one snmpwalk
        res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.get("community", "public"),
                       "-On", ctx.get("host", "localhost"), _BASE_OID], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}

        # Parse values
        voltage = None
        current = None
        output_load = None
        for line in res.stdout.splitlines():
            oid, value_str = _snmp_parse_line(line)
            if oid == None:
                continue
            if oid == _OID_VOLTAGE:
                if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit():
                    voltage = float(value_str)
            elif oid == _OID_CURRENT:
                if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit():
                    current = float(value_str)
            elif oid == _OID_OUTPUT_LOAD:
                if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit():
                    output_load = float(value_str)

        # If at least one metric was parsed, item "Output" exists
        if voltage != None or current != None or output_load != None:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "Output",
                            "params": {"voltage": (220, 220)},
                            "metrics": ["voltage", "current", "output_load"]
                        }
                    ]
                },
            }
        else:
            return {"changed": False, "msg": "no data found",
                    "data": {"discovery": []}}

    # Check mode: examine one item (only "Output" supported per spec)
    if item != "Output":
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch OIDs for the item
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.get("community", "public"),
                   "-On", ctx.get("host", "localhost"), _BASE_OID], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse values
    voltage = None
    current = None
    output_load = None
    for line in res.stdout.splitlines():
        oid, value_str = _snmp_parse_line(line)
        if oid == None:
            continue
        if oid == _OID_VOLTAGE:
            if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit():
                voltage = float(value_str)
        elif oid == _OID_CURRENT:
            if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit():
                current = float(value_str)
        elif oid == _OID_OUTPUT_LOAD:
            if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit():
                output_load = float(value_str)

    # If no data, return UNKNOWN
    if voltage == None and current == None and output_load == None:
        return {
            "changed": False,
            "msg": "no SNMP data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # State determination (voltage thresholds as per Checkmk's elphase.check_elphase pattern)
    state = "OK"
    details = []
    metrics = {}

    # Voltage: upper thresholds (WARN if >= warn, CRIT if >= crit)
    if voltage != None:
        if voltage >= crit_voltage:
            state = "CRIT"
        elif voltage >= warn_voltage:
            if state != "CRIT":
                state = "WARN"
        metrics["voltage"] = voltage
        details.append("Voltage: %f V" % voltage)

    # Current and output_load: only record if available
    if current != None:
        metrics["current"] = current
        details.append("Current: %f A" % current)
    if output_load != None:
        metrics["output_load"] = output_load
        details.append("Output load: %f %%" % output_load)

    # Format message
    msg = ", ".join(details) if details else "Phase Output"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
