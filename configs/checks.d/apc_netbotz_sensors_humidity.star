# ===== Starlark check: apc_netbotz_sensors_humidity =====
# Translate Checkmk plugin cmk.plugins.apc.agent_based.apc_netbotz_sensors
# Sensor type: humidity (%)
# Read-only check — no state changes

# Default thresholds for humidity (from Checkmk plugin)
DEFAULT_WARN = 60.0
DEFAULT_CRIT = 65.0
DEFAULT_WARN_LOWER = 35.0
DEFAULT_CRIT_LOWER = 30.0

def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # Fetch all humidity sensors via SNMP
        # Base OID for humidity: .1.3.6.1.4.1.5528.100.4.1.2.1 (netbotz v2)
        # We need the label (OID 1) and plugged_in_state (OID 4) to decide if active
        # We'll also fetch humidity reading (OID 2) and parse label+state
        # For simplicity, use snmpwalk on the base OID and parse output
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.5528.100.4.1.2.1"

        # Fetch humidity label (OID 1) and plugged_in_state (OID 4) via snmpwalk
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        # res.stdout lines look like: <oid>.<suffix> = STRING:<label>
        # We need to collect items with non-zero plugged_in_state.

        # Parse label and plugged_in_state lines
        lines = res.stdout.split("\n")
        # Map from suffix -> {label, plugged_in_state}
        suffix_map = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # Split OID and value
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Extract suffix (last component of OID)
            suffix = oid_part.rsplit(".", 1)[-1]
            # Determine type from OID
            if oid_part.startswith(".1.3.6.1.4.1.5528.100.4.1.2.1.1."):  # label
                label = value_part.strip().strip('"')
                suffix_map.setdefault(suffix, {})["label"] = label
            elif oid_part.startswith(".1.3.6.1.4.1.5528.100.4.1.2.1.4."):  # plugged_in_state
                # Plugged in state is 1 for true, 0 for false or empty
                val_str = value_part.strip()
                if val_str.isdigit():
                    suffix_map.setdefault(suffix, {})["plugged_in_state"] = int(val_str)
                else:
                    suffix_map.setdefault(suffix, {})["plugged_in_state"] = 0

        # Build list of items (humidity sensors)
        out = []
        for suffix, data in suffix_map.items():
            if data.get("plugged_in_state", 0) != 1:
                continue
            item = data.get("label", suffix)
            out.append({
                "item": item,
                "params": {
                    "warn": DEFAULT_WARN,
                    "crit": DEFAULT_CRIT,
                    "levels_lower": (DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER)
                },
                "metrics": ["humidity"]
            })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(out),
            "data": {"discovery": out}
        }

    # --- CHECK MODE ---
    # item name is in params
    item = params.get("item", "")
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    levels_lower = params.get("levels_lower", (DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER))
    warn_lower, crit_lower = levels_lower[0], levels_lower[1]

    # Fetch humidity sensor reading via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    # Humidity reading base OID: .1.3.6.1.4.1.5528.100.4.1.2.1.7.<suffix>
    # We need to find the suffix for this item's label.

    # First get label -> suffix mapping by walking labels again (simple approach)
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.5528.100.4.1.2.1.1"], mutates=False)
    lines = res.stdout.split("\n")
    label_to_suffix = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        suffix = oid_part.rsplit(".", 1)[-1]
        label = value_part.strip().strip('"')
        label_to_suffix[label] = suffix

    # Find suffix for requested item
    if item not in label_to_suffix:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    suffix = label_to_suffix[item]
    read_oid = ".1.3.6.1.4.1.5528.100.4.1.2.1.7." + suffix

    # Fetch humidity reading (value in tenths of a percent)
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, read_oid], mutates=False)
    lines = res.stdout.split("\n")
    humidity = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        if oid_part == read_oid:
            val_str = value_part.strip()
            # Check for empty/no value
            if val_str.isdigit():
                humidity = float(val_str) / 10.0
            else:
                humidity = None
            break

    # If humidity reading is missing, report UNKNOWN
    if humidity == None:
        return {
            "changed": False,
            "msg": "sensor reading unavailable for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state: humidity % should be within [lower_warn, upper_warn]
    state = "OK"
    # Upper levels: warn/crit above
    if humidity >= crit:
        state = "CRIT"
    elif humidity >= warn:
        state = "WARN"
    # Lower levels: warn/crit below
    if humidity <= crit_lower and state == "OK":
        state = "CRIT"
    elif humidity <= warn_lower and state == "OK":
        state = "WARN"

    # Build message: "Humidity 37.0 %"
    msg = "Humidity %f%%" % humidity

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": ""
        },
    }
