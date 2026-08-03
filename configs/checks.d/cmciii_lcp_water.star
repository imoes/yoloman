# Translated Checkmk check: cmciii_lcp_water
# Monitors Rittal CMCIII LCP water IN/OUT temperatures via SNMP.
# READ-ONLY Starlark check module for the yolo-man agent.

# SNMP base OID for the Rittal CMCIII LCP water section.
# The Checkmk SNMPTree fetches column OID "2" under base .1.3.6.1.4.1.2606.7.4.2.2.1.10
# which yields one value per row (a scalar read per-index). We fetch with -Oqv.
BASE_OID = "1.3.6.1.4.1.2606.7.4.2.2.1.10"
# The section OID index we probe to confirm an LCP device is present.
SYS_DESCR_OID = "1.3.6.1.2.1.1.1.0"
DESC_PREFIX = "Rittal LCP"


def _probe_present(ctx, params):
    """Confirm the Rittal LCP product is actually on this host via SNMP sysDescr."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_DESCR_OID],
        mutates=False,
    )
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    if not res.stdout:
        return False
    return res.stdout.find(DESC_PREFIX) != -1


def _fetch_water_section(ctx, params):
    """Fetch the raw string values of the water LCP section via SNMP.

    The Checkmk SNMPTree uses base .1.3.6.1.4.1.2606.7.4.2.2.1.10
    with column OID "2". In Net-SNMP terms this is a walk of
    <base>.2 which returns one value per row. We read all rows.
    """
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqv", host, BASE_OID + ".2"],
        mutates=False,
    )
    if res.rc == 127:
        return []
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.split("\n"):
        s = line.strip()
        if not s:
            continue
        rows.append(s)
    return rows


def _parse_section(rows):
    """Reproduce parse_cmciii_lcp_water: group lines into units, return Water unit's lines."""
    units = {}
    unit_lines = None
    for val in rows:
        if val.find(" Unit") != -1 and val.endswith(" Unit"):
            unit_name = val.split(" ")[0]
            unit_lines = []
            units[unit_name] = unit_lines
        elif unit_lines != None:
            unit_lines.append(val)
    if "Water" in units:
        return units["Water"]
    return []


def _parse_status(status_name):
    low = status_name.lower()
    if low == "ok":
        return "OK"
    if low == "warning":
        return "WARN"
    return "CRIT"


def _check_temperature(temp, params, warn, crit):
    """Grade a temperature against warn/crit levels (upper-level thresholds)."""
    if temp >= crit:
        return "CRIT"
    if temp >= warn:
        return "WARN"
    return "OK"


def _check_temperature_lower(temp, warn, crit):
    """Grade a temperature against lower-bound warn/crit levels."""
    if temp <= crit:
        return "CRIT"
    if temp <= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        if not _probe_present(ctx, params):
            return {
                "changed": False,
                "msg": "no Rittal LCP device found",
                "data": {"discovery": []},
            }
        rows = _fetch_water_section(ctx, params)
        section = _parse_section(rows)
        if not section:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        discovery = [
            {
                "item": "IN",
                "params": {},
                "metrics": ["temperature"],
            },
            {
                "item": "OUT",
                "params": {},
                "metrics": ["temperature"],
            },
        ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE: evaluate one item ("IN" or "OUT").
    item = params.get("item", "")
    if not _probe_present(ctx, params):
        return {
            "changed": False,
            "msg": "no Rittal LCP device found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    rows = _fetch_water_section(ctx, params)
    section = _parse_section(rows)
    if not section:
        return {
            "changed": False,
            "msg": "no water section data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    unit_status_name = section[2]
    unit_state = _parse_status(unit_status_name)

    if item == "IN":
        lines = section[5:12]
    elif item == "OUT":
        lines = section[14:21]
    else:
        return {
            "changed": False,
            "msg": "unknown item: " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # lines[0:5] are temperatures, lines[-1] is status.
    # ['18.2 °C', '50.0 °C', '40.0 °C', '13.0 °C', '10.0 °C', '3 %', 'OK']
    temperatures = []
    for x in lines[0:5]:
        parts = x.split(" ")
        temperatures.append(float(parts[0]))
    temp = temperatures[0]
    limits = temperatures[1:]
    status = _parse_status(lines[-1])

    # Temperature thresholds come from the Checkmk "temperature" ruleset.
    warn = params.get("warn", 70.0)
    crit = params.get("crit", 80.0)
    # Lower-bound levels from device limits: dev_levels_lower=(limits[3], limits[2])
    lower_warn = limits[3]
    lower_crit = limits[2]

    upper_state = _check_temperature(temp, params, warn, crit)
    # Combine device status and temperature grading; device status dominates on CRIT.
    if status == "CRIT":
        state = "CRIT"
    elif status == "WARN" and upper_state == "OK":
        state = "WARN"
    else:
        state = upper_state

    summary = "Unit: %s, %s %s°C" % (unit_status_name, item, str(temp))
    if upper_state != "OK":
        summary = summary + ", temperature " + upper_state

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "unit_status=%s" % unit_status_name,
        },
    }