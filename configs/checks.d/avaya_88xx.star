# ===== Starlark check module: avaya_88xx =====
# Reproduces cmk.plugins.avaya_88xx check logic (temperature + fan)
# READ-ONLY: never mutates, never changes state on host

# Fan state map: SNMP value -> (state, text)
_FAN_STATE_MAP = {
    "1": ("UNKNOWN", "Reported Unknown"),
    "2": ("OK", "Running"),
    "3": ("CRIT", "Down"),
}

# Default temperature levels (warn, crit)
_DEFAULT_TEMP_LEVELS = (55.0, 60.0)

def _snmpwalk(ctx, community, host, base_oid):
    """Run snmpwalk for base_oid and return lines list"""
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid
    ], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)
    return res.stdout.splitlines()

def _parse_snmp_table(ctx, community, host):
    """Parse avaya_88xx SNMP table (oids 2=fanstate, 3=temp)"""
    lines = _snmpwalk(ctx, community, host, ".1.3.6.1.4.1.2272.1.4.7.1.1")
    fanstate = []
    temp = []
    for line in lines:
        # Format: .1.3.6.1.4.1.2272.1.4.7.1.1.2.<idx> = INTEGER: <value>
        #         .1.3.6.1.4.1.2272.1.4.7.1.1.3.<idx> = INTEGER: <value>
        # Split by spaces: [oid_str, "INTEGER:", value_str]
        parts = line.strip().split()
        if len(parts) < 3:
            continue
        # Extract last part of OID to get index (we'll group by index)
        oid_str = parts[0]
        value = parts[2]
        if oid_str.endswith(".2"):
            fanstate.append(value)
        elif oid_str.endswith(".3"):
            temp.append(value)
    return fanstate, temp

def _check_temperature(reading, params):
    """Replicates cmk.plugins.lib.temperature.check_temperature logic for numeric reading"""
    warn_high = params.get("levels", _DEFAULT_TEMP_LEVELS)[0]
    crit_high = params.get("levels", _DEFAULT_TEMP_LEVELS)[1]
    warn_low = params.get("levels_lower", (None, None))[0] if params.get("levels_lower") else None
    crit_low = params.get("levels_lower", (None, None))[1] if params.get("levels_lower") else None

    # Upper bounds
    if crit_high != None and reading >= crit_high:
        return ("CRIT", "Critical (%f°C)" % reading)
    if warn_high != None and reading >= warn_high:
        return ("WARN", "Warning (%f°C)" % reading)
    # Lower bounds (if defined)
    if crit_low != None and reading <= crit_low:
        return ("CRIT", "Critical (%f°C)" % reading)
    if warn_low != None and reading <= warn_low:
        return ("WARN", "Warning (%f°C)" % reading)
    return ("OK", "OK (%f°C)" % reading)

def main(ctx, params):
    # Host and community params (snmpwalk needs these)
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode: enumerate items with metrics
    if params.get("_discover"):
        fanstate, temp = _parse_snmp_table(ctx, community, host)
        out = []
        for idx, temp_val in enumerate(temp):
            if temp_val:
                out.append({
                    "item": str(idx),
                    "params": {"levels": _DEFAULT_TEMP_LEVELS},
                    "metrics": ["temp"]
                })
        for idx, fan_val in enumerate(fanstate):
            if fan_val in _FAN_STATE_MAP:
                # Ensure we don't duplicate items (fan and temp share index)
                found = False
                for entry in out:
                    if entry["item"] == str(idx):
                        found = True
                        break
                if not found:
                    out.append({
                        "item": str(idx),
                        "params": {},
                        "metrics": []  # fan status yields no metrics
                    })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: one item
    item = params.get("item", "")
    fanstate, temp = _parse_snmp_table(ctx, community, host)

    # Determine if checking temperature or fan by checking item existence
    # In original code, both plugins exist: one for temp, one for fan.
    # Since discovery yields both types, we infer type by checking which list has this item.

    # Temperature check (item exists in temp list)
    if int(item) < len(temp) and temp[int(item)]:
        reading_str = temp[int(item)]
        if not reading_str.isdigit():
            return {
                "changed": False,
                "msg": "invalid temperature reading for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        reading = int(reading_str)
        state, summary = _check_temperature(reading, params)
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": state,
                "metrics": {"temp": reading},
                "details": ""
            }
        }

    # Fan status check (item exists in fanstate list)
    if int(item) < len(fanstate):
        state_key = fanstate[int(item)]
        if state_key not in _FAN_STATE_MAP:
            return {
                "changed": False,
                "msg": "unknown fan state for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        state, text = _FAN_STATE_MAP[state_key]
        return {
            "changed": False,
            "msg": text,
            "data": {
                "state": state,
                "metrics": {},
                "details": ""
            }
        }

    # Item not found
    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
