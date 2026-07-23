# Top-level constants (checkmk.icom_repeater_ps_volt defaults)
DEFAULT_LEVELS_LOWER = (13.5, 13.2)
DEFAULT_LEVELS_UPPER = (14.1, 14.4)

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), ".1.3.6.1.4.1.2021.8.1"
        ], mutates=False)
        # Parse SNMP output for "Power-supply voltage" line
        section = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0]
            value_part = parts[1]
            # Extract numeric OID suffix
            parts_oid = oid_part.strip().split(".")
            suffix = parts_oid[len(parts_oid) - 1] if len(parts_oid) > 0 else ""
            if suffix == "101":
                # This OID maps to "Power-supply voltage" according to agent section spec
                val = value_part.strip()
                if val.endswith("V"):
                    val_str = val[:-1]
                    # Guard: only parse if numeric (allow . and digits)
                    is_numeric = True
                    dot_count = 0
                    for c in val_str:
                        if c == '.':
                            dot_count = dot_count + 1
                        elif not c.isdigit():
                            is_numeric = False
                            break
                    if is_numeric and dot_count <= 1:
                        section["ps_voltage"] = float(val_str)
        if "ps_voltage" in section:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {
                                "levels_upper": DEFAULT_LEVELS_UPPER,
                                "levels_lower": DEFAULT_LEVELS_LOWER
                            },
                            "metrics": ["voltage"]
                        }
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }

    # Check mode (item is always "" for this check)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), ".1.3.6.1.4.1.2021.8.1"
    ], mutates=False)
    section = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0]
        value_part = parts[1]
        # Extract numeric OID suffix
        parts_oid = oid_part.strip().split(".")
        suffix = parts_oid[len(parts_oid) - 1] if len(parts_oid) > 0 else ""
        if suffix == "101":
            val = value_part.strip()
            if val.endswith("V"):
                val_str = val[:-1]
                # Guard: only parse if numeric (allow . and digits)
                is_numeric = True
                dot_count = 0
                for c in val_str:
                    if c == '.':
                        dot_count = dot_count + 1
                    elif not c.isdigit():
                        is_numeric = False
                        break
                if is_numeric and dot_count <= 1:
                    section["ps_voltage"] = float(val_str)

    if "ps_voltage" not in section:
        return {
            "changed": False,
            "msg": "Power supply voltage data not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    voltage = section["ps_voltage"]
    levels_upper = params.get("levels_upper", DEFAULT_LEVELS_UPPER)
    levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
    warn_upper = levels_upper[0]
    crit_upper = levels_upper[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]

    # Determine state based on voltage thresholds
    if voltage >= crit_upper or voltage <= crit_lower:
        state = "CRIT"
    elif voltage >= warn_upper or voltage <= warn_lower:
        state = "WARN"
    else:
        state = "OK"

    msg = "Voltage: %f V" % voltage
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": voltage},
            "details": ""
        }
    }