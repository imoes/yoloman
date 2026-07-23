# ===== module-level constants =====

# OID base for apc_ats_output section
_BASE_OID = ".1.3.6.1.4.1.318.1.1.8.5.4.3.1"
# OIDs in order: index(1), voltage(3), current(4), power(13), perc_load(10)
_OID_INDEX = "1"
_OID_VOLTAGE = "3"
_OID_CURRENT = "4"
_OID_POWER = "13"
_OID_PERC_LOAD = "10"

# Default thresholds from Checkmk source
_DEFAULT_VOLTAGE_MAX = ("fixed", (240.0, 250.0))
_DEFAULT_LOAD_PERC_MAX = ("fixed", (85.0, 95.0))


def _parse_snmp_output(stdout):
    """Parse snmpwalk output lines into dict {item: {metric: value}}."""
    parsed = {}
    lines = stdout.splitlines()
    for line in lines:
        # Format: .1.3.6.1.4.1.318.1.1.8.5.4.3.1.<index> = INTEGER: <value>
        # or similar depending on type, but Checkmk uses string_table
        # We'll collect all values per index from the walk
        eq_idx = line.find("=")
        if eq_idx < 0:
            continue
        oid_full = line[:eq_idx].strip()
        value_part = line[eq_idx + 1:].strip()
        # Extract leaf OID suffix
        if not oid_full.startswith(_BASE_OID):
            continue
        suffix = oid_full[len(_BASE_OID):].lstrip(".")
        # Split suffix by "." to get index and OID leaf
        parts = suffix.split(".")
        if len(parts) != 2:
            continue
        index, leaf_oid = parts
        if leaf_oid not in ["1", "3", "4", "10", "13"]:
            continue
        # Parse value
        # Format typically: "INTEGER: 230" or "Gauge32: 5" etc.
        colon_idx = value_part.find(":")
        if colon_idx < 0:
            continue
        value_str = value_part[colon_idx + 1:].strip()
        # Guard before risky float conversion
        value = float(value_str) if value_str.replace(".", "", 1).isdigit() or (value_str.startswith("-") and value_str[1:].replace(".", "", 1).isdigit()) else 0.0

        # Convert values: current is 0.1 factor
        factor = 0.1 if leaf_oid == "4" else 1.0
        value = value * factor

        item = parsed.setdefault(index, {})
        if leaf_oid == "3":
            item["voltage"] = value
        elif leaf_oid == "4":
            item["current"] = value
        elif leaf_oid == "10":
            item["perc_load"] = value
        elif leaf_oid == "13":
            item["power"] = value
    return parsed


def _check_levels(value, warn, crit, is_upper):
    """Return state (OK, WARN, CRIT) and updated metric based on levels."""
    # warn/crit are tuples of mode, value(s): ("fixed", (val,)) or ("no_levels", None)
    if warn == None or warn == ("no_levels", None):
        warn = None
    elif warn[0] == "fixed":
        warn = warn[1][0]
    else:
        warn = None

    if crit == None or crit == ("no_levels", None):
        crit = None
    elif crit[0] == "fixed":
        crit = crit[1][0]
    else:
        crit = None

    if crit != None:
        if is_upper:
            if value >= crit:
                return "CRIT"
        else:
            if value <= crit:
                return "CRIT"
    if warn != None:
        if is_upper:
            if value >= warn:
                return "WARN"
        else:
            if value <= warn:
                return "WARN"
    return "OK"


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Walk base OID
        res = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                community,
                "-On",
                host,
                _BASE_OID,
            ],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}
        parsed = _parse_snmp_output(res.stdout)
        discovery = []
        for item in parsed:
            # Suggested params: voltage max and load_perc max (others default to no_levels)
            suggested = {
                "output_voltage_max": _DEFAULT_VOLTAGE_MAX,
                "load_perc_max": _DEFAULT_LOAD_PERC_MAX,
            }
            metrics = ["volt", "watt", "current", "load_perc"]
            discovery.append({"item": item, "params": suggested, "metrics": metrics})
        return {
            "changed": False,
            "msg": "discovered %d phase(s)" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    # Walk base OID (same as discovery)
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            community,
            "-On",
            host,
            _BASE_OID,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    parsed = _parse_snmp_output(res.stdout)
    data = parsed.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "item %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    details_parts = []
    state_overall = "OK"

    # Voltage
    voltage = data.get("voltage")
    if voltage != None:
        warn_upper = params.get("output_voltage_max")
        crit_upper = params.get("output_voltage_max")
        # Use defaults if not specified in params
        if warn_upper == None:
            warn_upper = _DEFAULT_VOLTAGE_MAX
        if crit_upper == None:
            crit_upper = _DEFAULT_VOLTAGE_MAX
        warn_val = warn_upper[1][0] if warn_upper[0] == "fixed" else None
        crit_val = crit_upper[1][0] if crit_upper[0] == "fixed" else None
        st = _check_levels(voltage, warn_val, crit_val, True)
        if st != "OK":
            state_overall = st
        metrics["volt"] = voltage
        details_parts.append("Voltage: %f V" % voltage)

    # Power
    power = data.get("power")
    if power != None:
        warn_upper = params.get("output_power_max")
        crit_upper = params.get("output_power_max")
        if warn_upper == None:
            warn_upper = ("no_levels", None)
        if crit_upper == None:
            crit_upper = ("no_levels", None)
        warn_val = warn_upper[1][0] if warn_upper[0] == "fixed" else None
        crit_val = crit_upper[1][0] if crit_upper[0] == "fixed" else None
        st = _check_levels(power, warn_val, crit_val, True)
        if st != "OK":
            state_overall = st
        metrics["watt"] = power
        details_parts.append("Power: %f W" % power)

    # Current
    current = data.get("current")
    if current != None:
        warn_upper = params.get("output_current_max")
        crit_upper = params.get("output_current_max")
        if warn_upper == None:
            warn_upper = ("no_levels", None)
        if crit_upper == None:
            crit_upper = ("no_levels", None)
        warn_val = warn_upper[1][0] if warn_upper[0] == "fixed" else None
        crit_val = crit_upper[1][0] if crit_upper[0] == "fixed" else None
        st = _check_levels(current, warn_val, crit_val, True)
        if st != "OK":
            state_overall = st
        metrics["current"] = current
        details_parts.append("Current: %f A" % current)

    # Load % — -1 means not supported
    perc_load = data.get("perc_load")
    if perc_load != None and perc_load != -1:
        warn_lower = params.get("load_perc_min")
        warn_upper = params.get("load_perc_max")
        crit_lower = params.get("load_perc_min")
        crit_upper = params.get("load_perc_max")
        if warn_lower == None:
            warn_lower = ("no_levels", None)
        if crit_lower == None:
            crit_lower = ("no_levels", None)
        if warn_upper == None:
            warn_upper = _DEFAULT_LOAD_PERC_MAX
        if crit_upper == None:
            crit_upper = _DEFAULT_LOAD_PERC_MAX
        warn_val_upper = warn_upper[1][0] if warn_upper[0] == "fixed" else None
        crit_val_upper = crit_upper[1][0] if crit_upper[0] == "fixed" else None
        warn_val_lower = warn_lower[1][0] if warn_lower[0] == "fixed" else None
        crit_val_lower = crit_lower[1][0] if crit_lower[0] == "fixed" else None
        st_upper = _check_levels(perc_load, warn_val_upper, crit_val_upper, True)
        st_lower = _check_levels(perc_load, warn_val_lower, crit_val_lower, False)
        st = st_upper if st_upper == "CRIT" else (st_lower if st_lower == "CRIT" else (st_upper if st_upper == "WARN" else st_lower))
        if st != "OK":
            state_overall = st
        metrics["load_perc"] = perc_load
        details_parts.append("Load: %f %%" % perc_load)

    if not details_parts:
        details_parts.append("No metrics found")

    return {
        "changed": False,
        "msg": "; ".join(details_parts),
        "data": {"state": state_overall, "metrics": metrics, "details": ""},
    }
