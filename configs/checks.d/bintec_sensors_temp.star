# ===== Starlark check: checkmk.bintec_sensors_temp =====
# Discovery: enumerate temperature sensors (sensor_type == "1")
# Check: read temperature via SNMP and evaluate against levels

# Default parameters
DEFAULT_LEVELS = (35.0, 40.0)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.272.4.17.7.1.1.1.2"
        ], mutates=False)
        discovery = []
        # Parse snmpwalk output: OID = STRING: "description"
        # We need OID .1.3.6.1.4.1.272.4.17.7.1.1.1.{index}
        # We'll collect index->type and index->description maps
        # First get type (OID .3) and description (OID .2)
        res_oid2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.272.4.17.7.1.1.1.2"
        ], mutates=False)
        res_oid3 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.272.4.17.7.1.1.1.3"
        ], mutates=False)

        # Build index->type map from res_oid3 (type is .1.3.6.1.4.1.272.4.17.7.1.1.1.3)
        type_map = {}
        for line in res_oid3.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid_part = oid_part.strip()
            value_part = value_part.strip()
            # Extract index from OID: .1.3.6.1.4.1.272.4.17.7.1.1.1.3.<index>
            suffix = oid_part.rsplit(".", 1)
            if len(suffix) == 2:
                idx = suffix[1]
                # value_part is like "STRING: \"1\"" or "INTEGER: 1"
                val = value_part
                # Strip quotes and type prefix
                if val.startswith("STRING:"):
                    val = val[7:].strip().strip('"')
                elif val.startswith("INTEGER:"):
                    val = val[8:].strip()
                type_map[idx] = val

        # Build index->description map from res_oid2
        desc_map = {}
        for line in res_oid2.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid_part = oid_part.strip()
            value_part = value_part.strip()
            suffix = oid_part.rsplit(".", 1)
            if len(suffix) == 2:
                idx = suffix[1]
                val = value_part
                if val.startswith("STRING:"):
                    val = val[7:].strip().strip('"')
                elif val.startswith("INTEGER:"):
                    val = val[8:].strip()
                desc_map[idx] = val

        # Collect temperature sensors: type == "1"
        for idx in type_map:
            if type_map[idx] == "1":
                desc = desc_map.get(idx, "")
                if desc:
                    discovery.append({
                        "item": desc,
                        "params": {"levels": DEFAULT_LEVELS},
                        "metrics": ["temp"]
                    })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode
    item = params.get("item", "")
    warn = params.get("levels", DEFAULT_LEVELS)
    warn_upper = float(warn[0])
    crit_upper = float(warn[1])

    # Fetch description (OID .2) and value (OID .5)
    res_oid2 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.272.4.17.7.1.1.1.2"
    ], mutates=False)

    res_oid5 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.272.4.17.7.1.1.1.5"
    ], mutates=False)

    # Build description->value map
    desc_map = {}
    for line in res_oid2.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid_part = oid_part.strip()
        value_part = value_part.strip()
        suffix = oid_part.rsplit(".", 1)
        if len(suffix) == 2:
            idx = suffix[1]
            val = value_part
            if val.startswith("STRING:"):
                val = val[7:].strip().strip('"')
            elif val.startswith("INTEGER:"):
                val = val[8:].strip()
            desc_map[idx] = val

    # Build index->value map
    value_map = {}
    for line in res_oid5.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid_part = oid_part.strip()
        value_part = value_part.strip()
        suffix = oid_part.rsplit(".", 1)
        if len(suffix) == 2:
            idx = suffix[1]
            val = value_part
            if val.startswith("STRING:"):
                val = val[7:].strip().strip('"')
            elif val.startswith("INTEGER:"):
                val = val[8:].strip()
            value_map[idx] = val

    # Look up item via description
    reading = None
    for idx in desc_map:
        if desc_map[idx] == item:
            reading = value_map.get(idx)
            break

    if reading == None:
        return {
            "changed": False,
            "msg": "Sensor not found in SNMP data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse reading as integer (tenths of degree C per spec)
    temp_value = int(reading) / 10.0

    # Determine state
    if temp_value >= crit_upper:
        state = "CRIT"
    elif temp_value >= warn_upper:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature %s: %f C" % (item, temp_value),
        "data": {
            "state": state,
            "metrics": {"temp": temp_value},
            "details": ""
        }
    }
