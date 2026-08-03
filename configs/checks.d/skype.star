def main(ctx, params):
    if params.get("_discover"):
        return skype_discover(ctx)
    item = params.get("item", "")
    check_name = params.get("_check", "skype")
    return skype_check(ctx, item, params, check_name)


def skype_probe(ctx):
    res = ctx.run(["wmic", "path", "Win32_PerfRawData::*", "get", "*"], mutates=False)
    if res.rc == 127:
        return {"installed": False}
    if res.rc != 0:
        return {"installed": False}
    out = _parse_wmi(ctx, res.stdout)
    if not out:
        return {"installed": False}
    return {"installed": True, "tables": out}


def _parse_wmi(ctx, stdout):
    tables = {}
    lines = stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i = i + 1
            continue
        if line.startswith("<<<") and line.endswith("<<<"):
            name = line[3:-3]
            i = i + 1
            headers = []
            rows = []
            name_set = False
            if i < len(lines) and not lines[i].strip():
                i = i + 1
            else:
                pass
            while i < len(lines):
                row_line = lines[i].strip()
                if row_line.startswith("<<<"):
                    break
                if row_line:
                    cells = row_line.split("\t")
                    if not headers:
                        headers = cells
                    else:
                        rows.append(cells)
                i = i + 1
            tables[name] = {"headers": headers, "rows": rows}
        else:
            i = i + 1
    return tables


def _table_get(table, row_key, col_name):
    if table == None:
        return None
    headers = table["headers"]
    rows = table["rows"]
    col_index = -1
    for idx, h in enumerate(headers):
        norm = h.replace(" ", "").lower()
        target = col_name.replace(" ", "").lower()
        if norm == target:
            col_index = idx
            break
    if col_index < 0:
        return None
    row_index = -1
    if row_key == None or row_key == "":
        row_index = 0
        if len(rows) > 0:
            first = rows[0]
            if len(first) > 0:
                key_cell = first[0].strip('"')
                tot = key_cell.strip()
                if tot in ["_Total", "", "__Total__", "_Global"]:
                    row_index = 0
                else:
                    row_index = 0
    else:
        for idx, r in enumerate(rows):
            if len(r) > 0:
                cell = r[0].strip('"')
                if cell == row_key:
                    row_index = idx
                    break
        if row_index < 0:
            return None
    if row_index < 0 or row_index >= len(rows):
        return None
    row = rows[row_index]
    if col_index >= len(row):
        return None
    return row[col_index].strip('"') if row[col_index] else None


def _levels_upper(levels):
    if not levels:
        return None
    return levels.get("upper")


def _grade_upper(value, levels, name, label):
    if value == None:
        return ("UNKNOWN", 0, name + ": no data", label)
    lv = _levels_upper(levels)
    state = "OK"
    if lv != None:
        warn = lv[0]
        crit = lv[1]
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    return (state, value, "%s: %f" % (label, value), name)


def _grade_raw(value, levels, name, label):
    if value == None:
        return ("UNKNOWN", 0, label + ": no data", name)
    lv = _levels_upper(levels)
    state = "OK"
    if lv != None:
        warn = lv[0]
        crit = lv[1]
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    return (state, value, "%s: %d" % (label, value), name)


MCU_HEALTH = {
    "0": "OK: Normal",
    "1": "WARN: Loaded",
    "2": "WARN: Full",
    "3": "CRIT: Unavailable",
}


def _mcu_health(value, label):
    if value == None or value == "":
        return ("CRIT", label + ": unknown state", "mcu_" + label.lower())
    state = "CRIT"
    text = "unknown"
    for k, v in MCU_HEALTH.items():
        if k == value:
            parts = v.split(": ", 1)
            state = parts[0]
            text = parts[1]
            break
    return (state, 0, "%s: %s" % (label, text), "mcu_" + label.lower())


SKYPE_DEFAULTS = {
    "skype": {
        "failed_search_requests": {"upper": (1.0, 2.0)},
        "failed_locations_requests": {"upper": (1.0, 2.0)},
        "timedout_ad_requests": {"upper": (0.01, 0.02)},
        "5xx_responses": {"upper": (1.0, 2.0)},
        "asp_requests_rejected": {"upper": (1, 2)},
        "failed_file_requests": {"upper": (1.0, 2.0)},
        "join_failures": {"upper": (1, 2)},
        "failed_validate_cert": {"upper": (1, 2)},
    },
    "skype_conferencing": {
        "incomplete_calls": {"upper": (20.0, 40.0)},
        "create_conference_latency": {"upper": (5000.0, 10000.0)},
        "allocation_latency": {"upper": (5000.0, 10000.0)},
    },
    "skype_sip_stack": {
        "message_processing_time": {"upper": (1.0, 2.0)},
        "incoming_responses_dropped": {"upper": (1.0, 2.0)},
        "incoming_requests_dropped": {"upper": (1.0, 2.0)},
        "queue_latency": {"upper": (0.1, 0.2)},
        "sproc_latency": {"upper": (0.1, 0.2)},
        "throttled_requests": {"upper": (0.2, 0.4)},
        "local_503_responses": {"upper": (0.01, 0.02)},
        "timedout_incoming_messages": {"upper": (2, 4)},
        "holding_time_incoming": {"upper": (6.0, 12.0)},
        "flow_controlled_connections": {"upper": (1, 2)},
        "outgoing_queue_delay": {"upper": (2.0, 4.0)},
        "timedout_sends": {"upper": (0.01, 0.02)},
        "authentication_errors": {"upper": (1.0, 2.0)},
    },
    "skype_mediation_server": {
        "load_call_failure_index": {"upper": (10, 20)},
        "failed_calls_because_of_proxy": {"upper": (10, 20)},
        "failed_calls_because_of_gateway": {"upper": (10, 20)},
        "media_connectivity_failure": {"upper": (1, 2)},
    },
    "skype_edge_auth": {
        "bad_requests": {"upper": (20, 40)},
    },
    "skype_edge": {
        "authentication_failures": {"upper": (20, 40)},
        "allocate_requests_exceeding": {"upper": (20, 40)},
        "packets_dropped": {"upper": (200, 400)},
    },
    "skype_data_proxy": {
        "throttled_connections": {"upper": (1, 2)},
    },
    "skype_xmpp_proxy": {
        "failed_outbound_streams": {"upper": (0.01, 0.02)},
        "failed_inbound_streams": {"upper": (0.01, 0.02)},
    },
    "skype_mobile": {
        "requests_processing": {"upper": (10000, 20000)},
    },
}


def _defaults_for(check_name):
    return SKYPE_DEFAULTS.get(check_name, {})


def _merge_params(check_name, params):
    d = _defaults_for(check_name)
    for k, v in params.items():
        if k in d:
            dd = dict(d[k]) if d[k] != None else {}
            for kk, vv in v.items():
                dd[kk] = vv
            d[k] = dd
        else:
            d[k] = v
    return d


def skype_discover(ctx):
    info = skype_probe(ctx)
    if not info.get("installed"):
        return {"changed": False, "msg": "no Skype server found",
                "data": {"discovery": []}}
    tables = info["tables"]
    out = []
    if "LS:WEB - Address Book Web Query" in tables:
        out.append({"item": "LS:WEB - Address Book Web Query", "params": {},
                    "metrics": ["failed_search_requests"]})
    return {"changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}}


def skype_check(ctx, item, params, check_name):
    info = skype_probe(ctx)
    if not info.get("installed"):
        return {"changed": False,
                "msg": "no Skype server found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    tables = info["tables"]
    if item == "" or item not in tables:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cfg = _merge_params(check_name, params)
    metrics = {}
    parts = []
    worst = "OK"
    t = tables[item]

    if check_name == "skype":
        yield_from = []
        yield_from.append(grade_counter_raw(ctx, t, "WEB - Failed search requests/sec",
                         "failed_search_requests", "Failed search requests/sec",
                         cfg.get("failed_search_requests")))
        yield_from.append(grade_counter_raw(ctx, t, "WEB - Failed Get Locations Requests/Second",
                         "failed_location_requests", "Failed location requests/sec",
                         cfg.get("failed_locations_requests")))
        yield_from.append(grade_counter_raw(ctx, t, "WEB - Timed out Active Directory Requests/sec",
                         "failed_ad_requests", "Timeout AD requests/sec",
                         cfg.get("timedout_ad_requests")))
        yield_from.append(grade_counter_raw(ctx, t, "UCWA - HTTP 5xx Responses/Second",
                         "http_5xx", "HTTP 5xx/sec",
                         cfg.get("5xx_responses")))
        yield_from.append(grade_raw_counter(ctx, t, "Requests Rejected",
                         "asp_requests_rejected", "Requests rejected",
                         cfg.get("asp_requests_rejected")))
        for g, val, msg, name in yield_from:
            if val != 0 and val != None:
                metrics[name] = val
            parts.append(msg)
            worst = _worse(worst, g)
    return {"changed": False, "msg": "; ".join(parts),
            "data": {"state": worst, "metrics": metrics, "details": "; ".join(parts)}}


def grade_counter_raw(ctx, table, col, name, label, levels):
    raw = _table_get(table, None, col)
    if raw == None or not _is_number(raw):
        return ("UNKNOWN", 0, label + ": no data", name)
    value = float(raw)
    lv = _levels_upper(levels)
    state = "OK"
    if lv != None:
        warn = lv[0]
        crit = lv[1]
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    return (state, value, "%s: %f" % (label, value), name)


def grade_raw_counter(ctx, table, col, name, label, levels):
    raw = _table_get(table, None, col)
    if raw == None or not _is_number(raw):
        return ("UNKNOWN", 0, label + ": no data", name)
    value = float(raw)
    lv = _levels_upper(levels)
    state = "OK"
    if lv != None:
        warn = lv[0]
        crit = lv[1]
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    return (state, value, "%s: %f" % (label, value), name)


def _is_number(s):
    if s == None or s == "":
        return False
    i = 0
    for c in s:
        if c == "-" and i == 0:
            i = i + 1
            continue
        if c == "." and _count_dots(s) == 1:
            continue
        if c < "0" or c > "9":
            return False
        i = i + 1
    return True


def _count_dots(s):
    n = 0
    for c in s:
        if c == ".":
            n = n + 1
    return n


def _worse(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    oa = order.get(a, 3)
    ob = order.get(b, 3)
    if oa >= ob:
        return a
    return b