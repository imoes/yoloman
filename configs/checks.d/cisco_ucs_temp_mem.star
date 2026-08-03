# cisco_ucs_temp_mem — Temperature monitor for Cisco UCS memory sensors via SNMP
# Mirrors Checkmk check_plugin_cisco_ucs_temp_mem (check_ruleset_name="temperature")

# Temperature OID table (column base .1.3.6.1.4.1.9.9.719.1.30.12.1)
# columns: "2" = name (entity target name, e.g. "sys/.../mem-1/..."),
#          "6" = temp (temperature value as integer)
TEMPERATURE_BASE_OID = "1.3.6.1.4.1.9.9.719.1.30.12.1"
NAME_OID = "2"
VALUE_OID = "6"

# Checkmk default temperature levels for this check
DEFAULT_WARN = 75.0
DEFAULT_CRIT = 85.0

# Cisco UCS chassis/motherboard sysOIDs used by the original DETECT
CISCO_UCS_SYSOIDS = [
    "1.3.6.1.4.1.9.1.1682",
    "1.3.6.1.4.1.9.1.1683",
    "1.3.6.1.4.1.9.1.1684",
    "1.3.6.1.4.1.9.1.1685",
    "1.3.6.1.4.1.9.1.2178",
    "1.3.6.1.4.1.9.1.2179",
    "1.3.6.1.4.1.9.1.2424",
    "1.3.6.1.4.1.9.1.2492",
    "1.3.6.1.4.1.9.1.2493",
    "1.3.6.1.4.1.9.1.3100",
]


def _strip_type_tag(s):
    # Remove leading "TYPE: " and surrounding quotes that snmpget -Ov may emit.
    idx = s.find(": ")
    if idx != -1:
        s = s[idx + 2:]
    if len(s) >= 2 and s[0] == '"' and s[len(s) - 1] == '"':
        s = s[1:len(s) - 1]
    return s


def _grade_temperature(value, warn, crit):
    # Upper levels: warn/crit triggered when value >= threshold
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # --- DISCOVERY MODE ---
        # Confirm this is a Cisco UCS device via sysObjectID
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv",
             host, "1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_res.rc != 0 or not sys_res.stdout:
            return {"changed": False, "msg": "not a Cisco UCS device",
                    "data": {"discovery": []}}

        sys_oid = _strip_type_tag(sys_res.stdout)
        # The agent may return the OID with a leading "." — normalize
        if sys_oid.startswith("."):
            sys_oid = sys_oid[1:]

        matched = False
        for candidate in CISCO_UCS_SYSOIDS:
            if sys_oid == candidate or sys_oid.find(candidate) != -1:
                matched = True
                break
        if not matched:
            return {"changed": False, "msg": "not a Cisco UCS device",
                    "data": {"discovery": []}}

        # Walk the name column (.2) to discover memory temperature instances.
        # Each row OID looks like <base>.2.<index>; the value is the entity name.
        name_base = TEMPERATURE_BASE_OID + "." + NAME_OID
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn",
             host, name_base],
            mutates=False,
        )
        if walk.rc != 0 or not walk.stdout:
            return {"changed": False, "msg": "no memory temperature sensors found",
                    "data": {"discovery": []}}

        discovery = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            row_oid = parts[0]
            name_val = _strip_type_tag(parts[1])
            # Original discovery item: name.split("/")[3]
            segments = name_val.split("/")
            if len(segments) < 4:
                continue
            item = segments[3]
            discovery.append({
                "item": item,
                "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                "metrics": ["temperature"],
            })

        return {
            "changed": False,
            "msg": "discovered %d memory temperature sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    item = params.get("item", "")
    levels = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    if type(levels) == "list" and len(levels) >= 2:
        warn = float(levels[0])
        crit = float(levels[1])
    elif type(levels) == "tuple" and len(levels) >= 2:
        warn = float(levels[0])
        crit = float(levels[1])
    else:
        warn = params.get("warn", DEFAULT_WARN)
        crit = params.get("crit", DEFAULT_CRIT)

    # Re-walk the name column to locate the index for the requested item.
    name_base = TEMPERATURE_BASE_OID + "." + NAME_OID
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn",
         host, name_base],
        mutates=False,
    )
    if walk.rc != 0 or not walk.stdout:
        return {
            "changed": False,
            "msg": "no memory temperature sensors found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    target_index = None
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        row_oid = parts[0]
        name_val = _strip_type_tag(parts[1])
        segments = name_val.split("/")
        if len(segments) >= 4 and segments[3] == item:
            # index is the suffix after the name column base
            if row_oid.startswith(name_base + "."):
                target_index = row_oid[len(name_base) + 1:]
            else:
                target_index = row_oid[len(name_base):]
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "no memory temperature sensor for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Read the temperature value for the matched index from column .6
    value_oid = TEMPERATURE_BASE_OID + "." + VALUE_OID + "." + target_index
    get = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, value_oid],
        mutates=False,
    )
    if get.rc != 0 or not get.stdout:
        return {
            "changed": False,
            "msg": "could not read temperature for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = _strip_type_tag(get.stdout)
    temp = float(raw) if raw.replace(".", "", 1).isdigit() else 0.0

    state = _grade_temperature(temp, warn, crit)
    return {
        "changed": False,
        "msg": "Memory Temperature: %f C" % temp,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "",
        },
    }