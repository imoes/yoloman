# Translated Checkmk SNMP check: alcatel_temp
# Monitors Alcatel board/CPU temperatures via SNMP.
# This module is READ-ONLY: never mutates the system, always changed=False.

# SNMP base OID for the Alcatel temperature table
BASE_OID = ".1.3.6.1.4.1.6486.800.1.1.1.3.1.1.3.1"
# Column OIDs: 4 = Board temperature, 5 = CPU temperature
COL_BOARD = "4"
COL_CPU = "5"

def _walk_column(ctx, host, community, column_oid):
    """Walk a single SNMP column, return {index_suffix: value}."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    result = {}
    if res.rc != 0:
        return result
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # -Oqn format: "<full_oid> <value>"
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        value = parts[1]
        # Index suffix is everything after the column base OID + "."
        base_with_dot = column_oid + "."
        if oid_full.startswith(base_with_dot):
            idx = oid_full[len(base_with_dot):]
        elif oid_full == column_oid:
            idx = ""
        else:
            idx = oid_full
        result[idx] = value
    return result

def _get_scalar(ctx, host, community, oid):
    """Get a scalar SNMP value with -Oqv (bare value)."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if params.get("_discover"):
        # Discovery: probe for the sysObjectID to confirm this is an Alcatel device.
        # DETECT_ALCATEL = startswith(".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.6486.800")
        sys_obj_id = _get_scalar(ctx, host, community, "1.3.6.1.2.1.1.2.0")
        if sys_obj_id == None:
            # Device not reachable or SNMP not available — check does not apply.
            return {
                "changed": False,
                "msg": "no such device / not an Alcatel device",
                "data": {"discovery": []},
            }
        if not sys_obj_id.startswith(".1.3.6.1.4.1.6486.800"):
            # Not an Alcatel device — discovery yields nothing.
            return {
                "changed": False,
                "msg": "not an Alcatel device",
                "data": {"discovery": []},
            }

        # Walk both columns to determine slot count and which sensors are present.
        board_vals = _walk_column(ctx, host, community, BASE_OID + "." + COL_BOARD)
        cpu_vals = _walk_column(ctx, host, community, BASE_OID + "." + COL_CPU)

        # Collect all unique slot indices (suffixes) that have data in either column.
        all_indices = sorted(set(list(board_vals.keys()) + list(cpu_vals.keys())))

        with_slot = len(all_indices) != 1

        out = []
        # Map: sensor name -> column OID suffix
        sensor_cols = [("Board", COL_BOARD), ("CPU", COL_CPU)]

        for index, idx in enumerate(all_indices):
            for sensor_name, col_oid in sensor_cols:
                col_key = BASE_OID + "." + col_oid
                col_data = board_vals if sensor_name == "Board" else cpu_vals
                if idx in col_data:
                    raw = col_data[idx]
                    if raw == "0":
                        continue
                    if with_slot:
                        entry = {
                            "item": "Slot %d %s" % (index + 1, sensor_name),
                            "params": {"levels": (45.0, 50.0)},
                            "metrics": ["temperature"],
                        }
                    else:
                        entry = {
                            "item": sensor_name,
                            "params": {"levels": (45.0, 50.0)},
                            "metrics": ["temperature"],
                        }
                    out.append(entry)

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out},
        }

    # Check mode — evaluate one item.
    # Determine slot_index and sensor name from the item string.
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse the item: either "Board"/"CPU" (no slot) or "Slot N Board"/"Slot N CPU"
    parts = item.split()
    if len(parts) == 1:
        # Single-slot device
        slot_index = 0
        sensor = parts[0]
    elif len(parts) == 3 and parts[0] == "Slot":
        slot_index = int(parts[1]) - 1
        sensor = parts[2]
    else:
        return {
            "changed": False,
            "msg": "cannot parse item: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    if sensor not in ("Board", "CPU"):
        return {
            "changed": False,
            "msg": "unknown sensor type: %s" % sensor,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Determine which column OID to read based on sensor name.
    col_oid = COL_BOARD if sensor == "Board" else COL_CPU
    full_col_oid = BASE_OID + "." + col_oid

    # Walk the column to find the slot's index suffix.
    col_data = _walk_column(ctx, host, community, full_col_oid)
    if len(col_data) == 0:
        return {
            "changed": False,
            "msg": "sensor not found (no SNMP data for %s)" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Sort indices to match discovery ordering.
    sorted_indices = sorted(col_data.keys())
    if slot_index < 0 or slot_index >= len(sorted_indices):
        return {
            "changed": False,
            "msg": "slot index %d out of range for %s" % (slot_index, item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    idx_suffix = sorted_indices[slot_index]
    raw_val = col_data[idx_suffix]
    if raw_val == "0":
        # Sensor reports 0 — treat as not found per Checkmk logic.
        return {
            "changed": False,
            "msg": "sensor not found: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse the temperature value.
    temp_str = raw_val
    # Strip any potential SNMP type prefixes/quotes just in case.
    if temp_str.startswith("INTEGER:") or temp_str.startswith("STRING:"):
        temp_str = temp_str.split(":", 1)[1].strip()
        temp_str = temp_str.strip('"')

    # Convert to float safely.
    temp_val = 0.0
    # Try direct int/float conversion.
    try_int = True
    # Starlark has no try/except; we guard by checking if the string is numeric.
    # We attempt int() first, then float().
    # Use a helper approach: check if stripped value is a valid number.
    stripped_temp = temp_str.strip()
    # Handle negative numbers and decimals.
    numeric_chars = stripped_temp.lstrip("-").replace(".", "")
    if numeric_chars.isdigit() and stripped_temp.count(".") <= 1:
        temp_val = float(stripped_temp)
    else:
        return {
            "changed": False,
            "msg": "cannot parse temperature value '%s' for %s" % (temp_str, item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Apply temperature thresholds from params.
    levels = params.get("levels", (45.0, 50.0))
    warn = levels[0] if len(levels) >= 1 else 45.0
    crit = levels[1] if len(levels) >= 2 else 50.0

    state = "OK"
    if temp_val >= crit:
        state = "CRIT"
    elif temp_val >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature %s: %fC" % (item, temp_val),
        "data": {
            "state": state,
            "metrics": {"temperature": temp_val},
            "details": "Temperature sensor %s reads %fC (warn >= %f, crit >= %f)" % (
                item, temp_val, warn, crit
            ),
        },
    }