# Checkmk check: checkmk.nimble_latency_write (translated)
# Read-only Starlark check module for the yolo-man agent.

NIMBLE_BASE_OID = ".1.3.6.1.4.1.37447.1.2.1"
NIMBLE_SYS_OID = ".1.3.6.1.4.1.37447.3.1"

OID_LIST = [
    "3", "13", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31", "32", "33",
    "34", "39", "40", "41", "42", "43", "44", "45", "46", "47", "48", "49", "50", "51",
]

RANGE_KEYS = [
    ("total", "Total"),
    ("0.1", "0-0.1 ms"),
    ("0.2", "0.1-0.2 ms"),
    ("0.5", "0.2-0.5 ms"),
    ("1", "0.5-1.0 ms"),
    ("2", "1-2 ms"),
    ("5", "2-5 ms"),
    ("10", "5-10 ms"),
    ("20", "10-20 ms"),
    ("50", "20-50 ms"),
    ("100", "50-100 ms"),
    ("200", "100-200 ms"),
    ("500", "200-500 ms"),
    ("1000", "500+ ms"),
]

READ_OFFSET = 1
WRITE_OFFSET = 15

NIMBLE_READS_TYPE = "read"
NIMBLE_WRITES_TYPE = "write"

DEFAULT_RANGE_REFERENCE = "20"
DEFAULT_LEVELS = (10.0, 20.0)


def _unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0:1] == '"' and s[-1:] == '"':
        return s[1:-1]
    if len(s) >= 2 and s[0:1] == "'" and s[-1:] == "'":
        return s[1:-1]
    return s


def _is_nimble(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sys_oid = res.stdout.strip()
    if len(sys_oid) == 0:
        return False
    return sys_oid.startswith(NIMBLE_SYS_OID)


def _snmp_table(ctx, host, community, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        if oid_full.startswith(column_oid + "."):
            index = oid_full[len(column_oid) + 1:]
        else:
            index = ""
        rows.append((index, value))
    return rows


def _walk_all_columns(ctx, host, community):
    col0 = NIMBLE_BASE_OID + ".3"
    name_rows = _snmp_table(ctx, host, community, col0)
    if len(name_rows) == 0:
        return []

    indices = []
    names = {}
    for index, value in name_rows:
        indices.append(index)
        names[index] = _unquote(value)

    columns = {}
    for col_suffix in OID_LIST:
        col_oid = NIMBLE_BASE_OID + "." + col_suffix
        rows = _snmp_table(ctx, host, community, col_oid)
        col_map = {}
        for index, value in rows:
            col_map[index] = value
        columns[col_suffix] = col_map

    result = []
    for index in indices:
        row = []
        for col_suffix in OID_LIST:
            val = columns.get(col_suffix, {})
            row.append(val.get(index, ""))
        result.append((names.get(index, index), row))
    return result


def _parse_latency_table(snmp_rows):
    parsed = {}
    for vol_name, row in snmp_rows:
        vol_attrs = {}
        for ty, start_idx in [
            (NIMBLE_READS_TYPE, READ_OFFSET),
            (NIMBLE_WRITES_TYPE, WRITE_OFFSET),
        ]:
            values = row[start_idx : start_idx + 14]
            latencies = {}
            ranges = {}
            ordered_keys = []
            for i in range(min(len(RANGE_KEYS), len(values))):
                key, title = RANGE_KEYS[i]
                value_str = values[i]
                if not value_str or not value_str.lstrip("-").isdigit():
                    continue
                value = int(value_str)
                if key == "total":
                    latencies["total"] = value
                else:
                    if not key in ordered_keys:
                        ordered_keys.append(key)
                    ranges[key] = (title, value)
            latencies["ranges"] = ranges
            latencies["ordered_keys"] = ordered_keys
            vol_attrs[ty] = latencies
        parsed[vol_name] = vol_attrs
    return parsed


def _grade_percentage(value, levels):
    if levels == None or len(levels) < 2:
        return "OK"
    warn = float(levels[0])
    crit = float(levels[1])
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _check_item(params, data, ty):
    ty_data = data.get(ty)
    if ty_data == None:
        return {"state": "UNKNOWN", "msg": "No " + ty + " latency data", "metrics": {}, "details": ""}

    total_value = ty_data["total"]
    if total_value == 0:
        return {
            "state": "OK",
            "msg": "No current " + ty + " operations",
            "metrics": {},
            "details": "",
        }

    range_reference = params.get("range_reference", DEFAULT_RANGE_REFERENCE)
    range_ref_float = float(range_reference)
    levels = params.get(ty, list(DEFAULT_LEVELS))

    running_total_percent = 0.0
    metric_values = {}
    breakdown = []

    ordered_keys = ty_data["ordered_keys"]
    ranges = ty_data["ranges"]
    ref_range_entry = ranges.get(range_reference)
    ref_title = "At or above " + range_reference + " ms"
    if ref_range_entry != None:
        ref_title = "At or above " + ref_range_entry[0]

    for key in ordered_keys:
        title_value = ranges.get(key)
        if title_value == None:
            continue
        title, value = title_value
        percent_value = value / total_value * 100
        metric_name = "nimble_" + ty + "_latency_" + key.replace(".", "")
        metric_values[metric_name] = percent_value

        if float(key) >= range_ref_float:
            running_total_percent += percent_value
        breakdown.append((title, percent_value))

    agg_state = _grade_percentage(running_total_percent, levels)

    details_lines = [ref_title + ": " + ("%f" % running_total_percent) + "%"]
    details_lines.append("Latency breakdown:")
    for title, percent in breakdown:
        details_lines.append(title + ": " + ("%f" % percent) + "%")
    details = "\n".join(details_lines)

    agg_metric_name = "nimble_" + ty + "_latency_above_" + range_reference.replace(".", "")
    metric_values[agg_metric_name] = running_total_percent

    msg = "%f%% %s IO at or above %s ms" % (running_total_percent, ty, ref_title)
    return {"state": agg_state, "msg": msg, "metrics": metric_values, "details": details}


def _discover_items(section):
    out = []
    for vol_name, vol_attrs in section.items():
        if vol_attrs.get(NIMBLE_WRITES_TYPE):
            out.append({
                "item": vol_name,
                "params": {
                    "range_reference": DEFAULT_RANGE_REFERENCE,
                    "read": list(DEFAULT_LEVELS),
                    "write": list(DEFAULT_LEVELS),
                },
                "metrics": [
                    "nimble_write_latency_01",
                    "nimble_write_latency_02",
                    "nimble_write_latency_05",
                    "nimble_write_latency_1",
                    "nimble_write_latency_2",
                    "nimble_write_latency_5",
                    "nimble_write_latency_10",
                    "nimble_write_latency_20",
                    "nimble_write_latency_50",
                    "nimble_write_latency_100",
                    "nimble_write_latency_200",
                    "nimble_write_latency_500",
                    "nimble_write_latency_1000",
                    "nimble_write_latency_above_20",
                ],
            })
    return out


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_nimble(ctx, host, community):
        return {
            "changed": False,
            "msg": "Not a Nimble device",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        rows = _walk_all_columns(ctx, host, community)
        section = _parse_latency_table(rows)
        discovery = _discover_items(section)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    rows = _walk_all_columns(ctx, host, community)
    section = _parse_latency_table(rows)
    vol_data = section.get(item)
    if vol_data == None:
        return {
            "changed": False,
            "msg": "no such volume: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    result = _check_item(params, vol_data, NIMBLE_WRITES_TYPE)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"],
        },
    }