# Checkmk check: printer_output (-> SNMP-based printer output tray monitor)
# Translated to a read-only Starlark check module.

# Printer-MIB OIDs (per-printer, queried via SNMP):
# Input (printer_input): base .1.3.6.1.2.1.43.8.2.1
#   13=prtInputName, 18=prtInputDescription, 11=prtInputStatus,
#   8=prtInputCapacityUnit, 9=prtInputMaxCapacity, 10=prtInputCurrentLevel
# Output (printer_output): base .1.3.6.1.2.1.43.9.2.1
#   7=prtOutputName, 12=prtOutputDescription, 6=prtOutputStatus,
#   3=prtOutputCapacityUnit, 4=prtOutputMaxCapacity, 5=prtOutputRemainingCapacity
#
# This module implements printer_output (the requested check).

_PRINTER_IO_UNITS = {
    "-1": " unknown",
    "0": " unknown",
    "1": " unknown",
    "2": " unknown",
    "3": " 1/10000 in",
    "4": " micrometers",
    "8": " sheets",
    "16": " feet",
    "17": " meters",
    "18": " items",
    "19": " percent",
}

# printer_output table (.1.3.6.1.2.1.43.9.2.1): columns 7/12/6/3/4/5
_OUTPUT_TABLE_BASE = ".1.3.6.1.2.1.43.9.2.1"
_OUTPUT_NAME_COL = "7"
_OUTPUT_DESC_COL = "12"
_OUTPUT_STATUS_COL = "6"
_OUTPUT_UNIT_COL = "3"
_OUTPUT_MAX_COL = "4"
_OUTPUT_LEVEL_COL = "5"

# Known printer manufacturer sysObjectID prefixes (from lib.py PRINTER_MANUFACTURERS)
_MANUFACTURER_OIDS = [
    ".1.3.6.1.4.1.2435.2.3.9",
    ".1.3.6.1.4.1.1602",
    ".1.3.6.1.4.1.5502",
    ".1.3.6.1.4.1.25278",
    ".1.3.6.1.4.1.27748",
    ".1.3.6.1.4.1.11.2.3.9.1",
    ".1.3.6.1.4.1.18334",
    ".1.3.6.1.4.1.1347",
    ".1.3.6.1.4.1.2001.1",
    ".1.3.6.1.4.1.1129",
    ".1.3.6.1.4.1.367",
    ".1.3.6.1.4.1.236",
    ".1.3.6.1.4.1.253.8.62.1",
    ".1.3.6.1.4.1.683.6",
    ".1.3.6.1.4.1.10642",
    ".1.3.6.1.4.1.674",
    ".1.3.6.1.4.1.345",
    ".1.3.6.1.4.1.1248",
    ".1.3.6.1.4.1.641.2",
    ".1.3.6.1.4.1.641.52",
    ".1.3.6.1.4.1.641.1",
    ".1.3.6.1.4.1.641.3",
    ".1.3.6.1.4.1.641.51",
    ".1.3.6.1.4.1.396",
    ".1.3.6.1.4.1.44932",
    ".1.3.6.1.4.1.1472",
    ".1.3.6.1.4.1.2385",
    ".1.3.6.1.4.1.186",
    ".1.3.6.1.4.1.3835",
    ".1.3.6.1.4.1.2565",
    ".1.3.6.1.4.1.20438",
    ".1.3.6.1.4.1.33241",
    ".1.3.6.1.4.1.6345",
    ".1.3.6.1.4.1.2125",
    ".1.3.6.1.4.1.4228",
    ".1.3.6.1.4.1.314",
    ".1.3.6.1.4.1.16653",
    ".1.3.6.1.4.1.28959",
    ".1.3.6.1.4.1.28708",
    ".1.3.6.1.4.1.79",
    ".1.3.6.1.4.1.211",
    ".1.3.6.1.4.1.231",
    ".1.3.6.1.4.1.297",
    ".1.3.6.1.4.1.3369",
    ".1.3.6.1.4.1.116",
    ".1.3.6.1.4.1.2",
    ".1.3.6.1.4.1.28918",
    ".1.3.6.1.4.1.3793",
    ".1.3.6.1.4.1.11369",
    ".1.3.6.1.4.1.815",
    ".1.3.6.1.4.1.102",
    ".1.3.6.1.4.1.1552",
    ".1.3.6.1.4.1.279",
    ".1.3.6.1.4.1.10504",
    ".1.3.6.1.4.1.24807",
    ".1.3.6.1.4.1.42406",
    ".1.3.6.1.4.1.263",
    ".1.3.6.1.4.1.22624",
    ".1.3.6.1.4.1.25549",
    ".1.3.6.1.4.1.128",
    ".1.3.6.1.4.1.294",
    ".1.3.6.1.4.1.38191",
    ".1.3.6.1.4.1.950",
    ".1.3.6.1.4.1.25816",
    ".1.3.6.1.4.1.28878",
    ".1.3.6.1.4.1.40463",
    ".1.3.6.1.4.1.122",
    ".1.3.6.1.4.1.119",
]

_STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

_AVAIL_MAP = {
    0: ("AVAILABLE_AND_IDLE", "OK"),
    2: ("AVAILABLE_AND_STANDBY", "OK"),
    4: ("AVAILABLE_AND_ACTIVE", "OK"),
    6: ("AVAILABLE_AND_BUSY", "OK"),
    1: ("UNAVAILABLE_AND_ON_REQUEST", "WARN"),
    3: ("UNAVAILABLE_BECAUSE_BROKEN", "CRIT"),
    5: ("UNKNOWN", "UNKNOWN"),
    7: ("UNKNOWN", "UNKNOWN"),
}


def _worse(current, new):
    if _STATE_RANK.get(new, 0) > _STATE_RANK.get(current, 0):
        return new
    return current


def _int_or_zero(s):
    if s == None or s == "":
        return 0
    if s.startswith("-"):
        body = s[1:]
    else:
        body = s
    if not body.isdigit():
        return 0
    val = int(s)
    return val


def _parse_status(status_raw):
    status_val = _int_or_zero(status_raw)
    transitioning = bool(status_val & 64)
    offline = bool(status_val & 32)
    if status_val & 16:
        alert = "CRITICAL"
    elif status_val & 8:
        alert = "NON_CRITICAL"
    else:
        alert = "NONE"
    avail_index = status_val - (status_val // 8) * 8
    if avail_index < 0:
        avail_index = avail_index + 8
    name, state = _AVAIL_MAP.get(avail_index, ("UNKNOWN", "UNKNOWN"))
    return name, state, alert, offline, transitioning


def _walk_index(ctx, community, host, column_oid, index):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, column_oid + "." + index],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _walk_column(ctx, community, host, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = {}
    if res.rc != 0 or res.stdout.strip() == "":
        return rows
    for line in res.stdout.splitlines():
        if line.strip() == "":
            continue
        space = line.find(" ")
        if space == -1:
            continue
        oid = line[:space]
        value = line[space + 1:]
        if not oid.startswith(column_oid + "."):
            continue
        index = oid[len(column_oid) + 1:]
        rows[index] = value
    return rows


def _parse_row(name, description, status_raw, unit_raw, max_raw, level_raw):
    avail_name, avail_state, alert, offline, transitioning = _parse_status(status_raw)
    disp_name = name
    if name == "unknown" or name == "":
        if description and description != "":
            disp_name = description
        else:
            disp_name = "tray"
    unit_str = ""
    if unit_raw != "":
        unit_str = _PRINTER_IO_UNITS.get(unit_raw, " unknown")
    capacity_max = _int_or_zero(max_raw)
    level = _int_or_zero(level_raw)
    return {
        "name": disp_name,
        "description": description,
        "availability_name": avail_name,
        "availability_state": avail_state,
        "alert": alert,
        "offline": offline,
        "transitioning": transitioning,
        "capacity_unit": unit_str,
        "capacity_max": capacity_max,
        "level": level,
    }


def _probe_printer(ctx, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return False
    sys_id = res.stdout.strip()
    is_manufacturer = False
    for oid in _MANUFACTURER_OIDS:
        if sys_id.startswith(oid):
            is_manufacturer = True
            break
    if not is_manufacturer:
        return False
    res43 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.43"],
        mutates=False,
    )
    if res43.rc != 0 or res43.stdout.strip() == "":
        return False
    return True


def _build_section(ctx, community, host):
    trays = {}
    statuses = _walk_column(ctx, community, host, _OUTPUT_TABLE_BASE + "." + _OUTPUT_STATUS_COL)
    for index, status_val in statuses.items():
        name = _walk_index(ctx, community, host, _OUTPUT_TABLE_BASE + "." + _OUTPUT_NAME_COL, index)
        description = _walk_index(ctx, community, host, _OUTPUT_TABLE_BASE + "." + _OUTPUT_DESC_COL, index)
        unit = _walk_index(ctx, community, host, _OUTPUT_TABLE_BASE + "." + _OUTPUT_UNIT_COL, index)
        max_val = _walk_index(ctx, community, host, _OUTPUT_TABLE_BASE + "." + _OUTPUT_MAX_COL, index)
        level_val = _walk_index(ctx, community, host, _OUTPUT_TABLE_BASE + "." + _OUTPUT_LEVEL_COL, index)
        tray = _parse_row(name, description, status_val, unit, max_val, level_val)
        trays[tray["name"]] = tray
    return trays


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    capacity_levels = params.get("capacity_levels", (0.0, 0.0))
    if capacity_levels and len(capacity_levels) >= 2:
        warn_level = capacity_levels[0]
        crit_level = capacity_levels[1]
    else:
        warn_level = 0.0
        crit_level = 0.0

    is_printer = _probe_printer(ctx, community, host)

    if params.get("_discover"):
        if not is_printer:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        section = _build_section(ctx, community, host)
        discovery = []
        for tray in section.values():
            if tray["description"] == "":
                continue
            if tray["capacity_max"] == 0:
                continue
            if tray["availability_state"] == "CRIT" or tray["availability_name"] == "UNKNOWN":
                continue
            discovery.append({
                "item": tray["name"],
                "params": {"capacity_levels": capacity_levels},
                "metrics": ["level_percent"],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if not is_printer:
        return {"changed": False,
                "msg": "host is not a recognized printer (sysObjectID mismatch or Printer-MIB absent)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _build_section(ctx, community, host)
    tray = section.get(item)
    if tray == None:
        return {"changed": False,
                "msg": "no such tray: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summaries = []
    out_state = "OK"

    if tray["description"]:
        summaries.append(tray["description"])

    if tray["offline"]:
        out_state = "CRIT"
        summaries.append("Offline")

    if tray["transitioning"]:
        summaries.append("Transitioning")

    summaries.append("Status: " + tray["availability_name"].replace("_", " ").capitalize())
    out_state = _worse(out_state, tray["availability_state"])

    if tray["alert"] == "NONE":
        summaries.append("Alerts: None")
    else:
        summaries.append("Alerts: " + tray["alert"])
    if tray["alert"] == "CRITICAL":
        out_state = _worse(out_state, "CRIT")
    elif tray["alert"] == "NON_CRITICAL":
        out_state = _worse(out_state, "WARN")

    level = tray["level"]
    capacity_max = tray["capacity_max"]
    capacity_unit = tray["capacity_unit"]

    if level in [-1, -2] or level < -3:
        return {"changed": False,
                "msg": "; ".join(summaries),
                "data": {"state": out_state, "metrics": {}, "details": ""}}

    if capacity_max in (-2, -1, 0):
        if capacity_unit != " unknown":
            summaries.append("Capacity: %s%s" % (level, capacity_unit))
        return {"changed": False,
                "msg": "; ".join(summaries),
                "data": {"state": out_state, "metrics": {}, "details": ""}}

    if capacity_unit != " unknown":
        summaries.append("Maximal capacity: %s%s" % (capacity_max, capacity_unit))

    quantity_message = "filled"

    if level == -3:
        summaries.append("At least one %s" % quantity_message)
        return {"changed": False,
                "msg": "; ".join(summaries),
                "data": {"state": out_state, "metrics": {}, "details": ""}}

    percent = 0.0
    if capacity_max > 0:
        percent = 100.0 * level / capacity_max
    else:
        percent = 0.0

    if percent >= crit_level and crit_level >= 0:
        out_state = _worse(out_state, "CRIT")
    elif percent >= warn_level and warn_level >= 0:
        out_state = _worse(out_state, "WARN")

    summaries.append("Remaining: %f%%" % percent)
    return {"changed": False,
            "msg": "; ".join(summaries),
            "data": {"state": out_state,
                     "metrics": {"level_percent": percent},
                     "details": ""}}