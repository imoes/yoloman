# Checkmk check: cmciii_temp_in_out
# Read-only Starlark check module for the yolo-man agent.
# Monitors temperature sensors on a Rittal LCP via SNMP.

DESC_OID = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
VALUE_OID = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.6"
SYS_DESC_OID = ".1.3.6.1.2.1.1.1.0"

DEFAULT_WARN = 30
DEFAULT_CRIT = 35


def _is_rittal_lcp(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_DESC_OID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    desc = res.stdout.strip().strip('"').strip("'")
    return desc.startswith("Rittal LCP")


def _walk_sensors(ctx, host, community, base_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
        mutates=False,
    )
    sensors = {}
    if res.rc != 0:
        return sensors
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        space = line.find(" ")
        if space == -1:
            continue
        oid = line[:space]
        val = line[space + 1:]
        if oid.startswith(base_oid + "."):
            idx = oid[len(base_oid) + 1:]
        else:
            idx = oid
        sensors[idx] = val
    return sensors


def _get_value(ctx, host, community, col_oid, index):
    full_oid = col_oid + "." + index
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, full_oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    val = res.stdout.strip().strip('"').strip("'")
    return val


def _parse_temp(raw):
    cleaned = raw.strip()
    if cleaned.endswith(" C") or cleaned.endswith("c"):
        cleaned = cleaned[:-1].strip()
    test = cleaned
    if test.startswith("-") or test.startswith("+"):
        test = test[1:]
    if test.find(".") != -1:
        parts = test.split(".")
        if len(parts) != 2:
            return None
        if not (parts[0].isdigit() and parts[1].isdigit()):
            return None
    else:
        if not test.isdigit():
            return None
    return float(cleaned)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_rittal_lcp(ctx, host, community):
            return {
                "changed": False,
                "msg": "not a Rittal LCP device",
                "data": {"discovery": []},
            }
        desc_map = _walk_sensors(ctx, host, community, DESC_OID)
        if len(desc_map) == 0:
            return {
                "changed": False,
                "msg": "no temp_in_out sensors found",
                "data": {"discovery": []},
            }
        discovery = []
        for index, desc in desc_map.items():
            discovery.append({
                "item": desc,
                "params": {"_item_key": index},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)

    if not _is_rittal_lcp(ctx, host, community):
        return {
            "changed": False,
            "msg": "not a Rittal LCP device",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "host does not respond as a Rittal LCP",
            },
        }

    index = params.get("_item_key")
    if index == None:
        desc_map = _walk_sensors(ctx, host, community, DESC_OID)
        found_index = None
        for idx, desc in desc_map.items():
            if desc == item:
                found_index = idx
                break
        if found_index == None:
            return {
                "changed": False,
                "msg": "sensor not found: " + str(item),
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "no sensor with description '" + str(item) + "'",
                },
            }
        index = found_index

    raw_value = _get_value(ctx, host, community, VALUE_OID, index)
    if raw_value == "":
        return {
            "changed": False,
            "msg": "no value for sensor: " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "could not read temperature value for index " + str(index),
            },
        }

    temp_val = _parse_temp(raw_value)
    if temp_val == None:
        return {
            "changed": False,
            "msg": "invalid temperature value: " + raw_value,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "value '" + raw_value + "' is not numeric",
            },
        }

    state = "OK"
    if temp_val >= float(crit):
        state = "CRIT"
    elif temp_val >= float(warn):
        state = "WARN"

    return {
        "changed": False,
        "msg": "%s: %f C" % (item, temp_val),
        "data": {
            "state": state,
            "metrics": {"temperature": temp_val},
            "details": "sensor: " + str(item) + ", index: " + str(index),
        },
    }