# Range keys in order: (key, title). First is "total".
_NIMBLE_RANGE_KEYS = [
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

_NIMBLE_READ_START = 1
_NIMBLE_WRITE_START = 15
_NIMBLE_NUM_VALUES = 14
_NIMBLE_OID_COLS = [
    "3", "13", "21", "22", "23", "24", "25", "26", "27", "28", "29",
    "30", "31", "32", "33", "34", "39", "40", "41", "42", "43", "44",
    "45", "46", "47", "48", "49", "50", "51",
]

_DEC_POWERS = [1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0, 10000000.0]


def _dec_power(n):
    """Return 10**n without using ** operator, for non-negative n up to 7."""
    if n < 0 or n > 7:
        return 10.0
    return _DEC_POWERS[n]


def _is_int_str(s):
    if not s:
        return False
    if s[0] == "-":
        return len(s) > 1 and s[1:].isdigit()
    return s.isdigit()


def _safe_int(s):
    if s and s.lstrip("-").isdigit():
        return int(s)
    return None


def _safe_float(s):
    if not s:
        return None
    neg = False
    rest = s
    if rest[0] == "-":
        neg = True
        rest = rest[1:]
    if rest == "":
        return None
    if "." in rest:
        whole, frac = rest.split(".", 1)
        if not whole and not frac:
            return None
        if whole and not whole.isdigit():
            return None
        if frac and not frac.isdigit():
            return None
        val = 0.0
        if whole:
            val = float(int(whole))
        if frac:
            val += float(int(frac)) / _dec_power(len(frac))
        return -val if neg else val
    else:
        if not rest.isdigit():
            return None
        return float(-int(rest)) if neg else float(int(rest))


def _parse_nimble_latency(string_table):
    """Parse the SNMP string table into {vol_name: {type: LatencyData}}.

    LatencyData = {"total": int, "ranges": {key: [title, value], ...}}
    """
    parsed = {}
    for line in string_table:
        if len(line) < 1:
            continue
        vol_name = line[0]
        for ty, start_idx in [
            ("read", _NIMBLE_READ_START),
            ("write", _NIMBLE_WRITE_START),
        ]:
            end_idx = start_idx + _NIMBLE_NUM_VALUES
            values = line[start_idx:end_idx]
            latencies = {}
            ranges = {}
            for (key, title), value_str in zip(_NIMBLE_RANGE_KEYS, values):
                if not _is_int_str(value_str):
                    continue
                value = _safe_int(value_str)
                if value == None:
                    continue
                if key == "total":
                    latencies["total"] = value
                else:
                    ranges[key] = [title, value]
            if "total" in latencies:
                latencies["ranges"] = ranges
                parsed.setdefault(vol_name, {})[ty] = latencies
    return parsed


def _walk_snmp_rows(ctx, host, community):
    """Walk the Nimble latency base OID and return the string table.

    Returns a list of rows; each row is [vol_name, col3, col13, col21, ...].
    Returns None on SNMP failure.
    """
    base_oid = "1.3.6.1.4.1.37447.1.2.1"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-OQ", host, base_oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    rows = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        space_idx = line.find(" ")
        if space_idx == -1:
            continue
        oid = line[:space_idx]
        val = line[space_idx + 1:].strip()
        suffix = oid[len(base_oid) + 1:]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        vol_index = ".".join(parts[1:])
        rows.setdefault(vol_index, {})[col] = val

    string_table = []
    for vol_index in sorted(rows.keys()):
        row_data = rows[vol_index]
        vol_name = row_data.get("3", "")
        row = [vol_name]
        for c in _NIMBLE_OID_COLS:
            row.append(row_data.get(c, ""))
        string_table.append(row)
    return string_table


def _grade_levels(value, levels):
    """Grade a numeric value against (warn, crit) levels (upper levels)."""
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    """Checkmk nimble_latency check translated to read-only Starlark.

    Supports discovery (params['_discover']=True) and per-item check for both
    read and write IO latency.
    """
    if params.get("_discover"):
        host = params.get("host", "")
        community = params.get("community", "public")
        rows = _walk_snmp_rows(ctx, host, community)
        if rows == None:
            return {"changed": False,
                    "msg": "SNMP walk to Nimble device failed; no latencies found",
                    "data": {"discovery": [],
                             "host_labels": {"cmk/os_family": "linux"}}}

        if len(rows) == 0:
            return {"changed": False,
                    "msg": "No Nimble latency data found on host",
                    "data": {"discovery": [],
                             "host_labels": {"cmk/os_family": "linux"}}}

        parsed = _parse_nimble_latency(rows)
        out = []
        for vol_name, vol_attrs in parsed.items():
            if vol_attrs.get("read") != None:
                out.append({"item": vol_name,
                            "params": {"direction": "read",
                                       "warn": 10.0, "crit": 20.0,
                                       "range_reference": "20"},
                            "metrics": ["nimble_read_latency_10",
                                        "nimble_read_latency_20",
                                        "nimble_read_latency_50",
                                        "nimble_read_latency_100",
                                        "nimble_read_latency_200",
                                        "nimble_read_latency_500",
                                        "nimble_read_latency_1000"]})
            if vol_attrs.get("write") != None:
                out.append({"item": vol_name,
                            "params": {"direction": "write",
                                       "warn": 10.0, "crit": 20.0,
                                       "range_reference": "20"},
                            "metrics": ["nimble_write_latency_10",
                                        "nimble_write_latency_20",
                                        "nimble_write_latency_50",
                                        "nimble_write_latency_100",
                                        "nimble_write_latency_200",
                                        "nimble_write_latency_500",
                                        "nimble_write_latency_1000"]})
        msg = "discovered %d Nimble latency services" % len(out)
        return {"changed": False, "msg": msg,
                "data": {"discovery": out,
                         "host_labels": {"cmk/os_family": "linux"}}}

    # Check mode
    host = params.get("host", "")
    community = params.get("community", "public")
    direction = params.get("direction", "read")
    item = params.get("item", "")

    rows = _walk_snmp_rows(ctx, host, community)
    if rows == None:
        return {"changed": False,
                "msg": "SNMP walk to Nimble device failed; cannot check latency",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_nimble_latency(rows)
    vol_data = parsed.get(item, {})
    ty_data = vol_data.get(direction, {})
    if ty_data == None:
        return {"changed": False,
                "msg": "No %s latency data for volume '%s'" % (direction, item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_value = ty_data.get("total", 0)
    if total_value == 0:
        return {"changed": False,
                "msg": "No current %s operations" % direction,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    range_reference = params.get("range_reference", "20")
    ref_float = _safe_float(range_reference)
    if ref_float == None:
        ref_float = 20.0

    running_total = 0.0
    metrics = {}
    breakdown_lines = []
    for key, kv in ty_data["ranges"].items():
        title = kv[0]
        value = kv[1]
        key_nodot = key.replace(".", "")
        metric_name = "nimble_%s_latency_%s" % (direction, key_nodot)
        percent = value / total_value * 100
        metrics[metric_name] = percent
        key_float = _safe_float(key)
        if key_float != None and key_float >= ref_float:
            running_total += percent
        breakdown_lines.append("%s: %d ops (%f%%)" % (title, value, percent))

    levels = (10.0, 20.0)
    warn_p = params.get("warn", None)
    crit_p = params.get("crit", None)
    if warn_p != None and crit_p != None:
        levels = (warn_p, crit_p)
    dir_levels = params.get(direction, None)
    if dir_levels != None:
        levels = dir_levels

    state = _grade_levels(running_total, levels)

    ref_title = "10-20 ms"
    ranges = ty_data.get("ranges", {})
    if range_reference in ranges:
        ref_title = ranges[range_reference][0]

    msg = "%s at or above %s: %f%%" % (direction, ref_title, running_total)
    details = "Latency breakdown:\n" + "\n".join(breakdown_lines)

    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}