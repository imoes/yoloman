# ibm_svc_enclosure.star - translated from Checkmk check mk.plugins.ibm.agent_based.ibm_svc_enclosure

# Column name mappings based on field counts
_HEADER_9 = [
    "id",
    "status",
    "type",
    "product_MTM",
    "serial_number",
    "total_canisters",
    "online_canisters",
    "online_PSUs",
    "drive_slots",
]

_HEADER_13 = [
    "id",
    "status",
    "type",
    "managed",
    "IO_group_id",
    "IO_group_name",
    "product_MTM",
    "serial_number",
    "total_canisters",
    "online_canisters",
    "total_PSUs",
    "online_PSUs",
    "drive_slots",
]

_HEADER_15 = [
    "id",
    "status",
    "type",
    "managed",
    "IO_group_id",
    "IO_group_name",
    "product_MTM",
    "serial_number",
    "total_canisters",
    "online_canisters",
    "total_PSUs",
    "online_PSUs",
    "drive_slots",
    "total_fan_modules",
    "online_fan_modules",
]

_HEADER_17 = [
    "id",
    "status",
    "type",
    "managed",
    "IO_group_id",
    "IO_group_name",
    "product_MTM",
    "serial_number",
    "total_canisters",
    "online_canisters",
    "total_PSUs",
    "online_PSUs",
    "drive_slots",
    "total_fan_modules",
    "online_fan_modules",
    "total_sems",
    "online_sems",
]

# Mapping from data field to check_levels key and display label
_COMPONENT_FIELDS = [
    ("canisters", "canisters"),
    ("PSUs", "PSUs"),
    ("fan_modules", "fan modules"),
    ("sems", "secondary expander modules"),
]

def _get_header(num_fields):
    if num_fields == 9:
        return _HEADER_9
    if num_fields == 13:
        return _HEADER_13
    if num_fields == 15:
        return _HEADER_15
    if num_fields == 17:
        return _HEADER_17
    return None

def _try_int(value):
    if value == None:
        return None
    if type(value) != "string":
        return None
    v = value.strip()
    if v == "" or v == "-":
        return None
    neg = v[0:1] == "-"
    digits = v[neg:]
    if digits == "":
        return None
    ok = True
    for ch in digits:
        if ch < "0" or ch > "9":
            ok = False
            break
    if not ok:
        return None
    n = 0
    for ch in digits:
        n = n * 10 + (ord(ch) - ord("0"))
    return -n if neg else n

def _parse_enclosure_output(stdout):
    enclosures = {}
    if stdout == None or stdout == "":
        return enclosures
    lines = stdout.splitlines()
    parsed_lines = []
    for line in lines:
        line = line.strip()
        if line == "" or line.startswith("#"):
            continue
        if " command not found" in line:
            continue
        parsed_lines.append(line)
    if len(parsed_lines) == 0:
        return enclosures
    header = None
    for line in parsed_lines:
        fields = line.split(":")
        if len(fields) == 0:
            continue
        first = fields[0].strip()
        if first in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = fields
        else:
            if header == None:
                hlen = len(fields)
                header = _get_header(hlen)
            if header == None:
                continue
            row = {}
            name = None
            for i, val in enumerate(fields):
                if i == 0:
                    name = val.strip()
                elif i - 1 < len(header):
                    col_name = header[i - 1]
                    if col_name != "id":
                        row[col_name] = val.strip()
            if name != None:
                enclosures.setdefault(name, row)
    return enclosures

def _grade_enclosure(data, params):
    state = "OK"
    msgs = []
    details = []
    esc_status = data.get("status", "")
    if esc_status == "online":
        state = "OK"
    else:
        state = "CRIT"
    msgs.append("Status: " + str(esc_status))
    details.append("Enclosure " + str(data.get("id", "")) + " status: " + str(esc_status))
    online_metrics = {}
    for field, label in _COMPONENT_FIELDS:
        online_val = _try_int(data.get("online_" + field))
        total_val = _try_int(data.get("total_" + field))
        if online_val == None:
            continue
        raw_param = params.get("levels_lower_online_" + field)
        levels = None
        if type(raw_param) == "list" and len(raw_param) == 2:
            levels = raw_param
        elif total_val != None:
            levels = [total_val, total_val]
        if levels != None and len(levels) == 2:
            warn_val = levels[0]
            crit_val = levels[1]
        else:
            warn_val = None
            crit_val = None
        comp_state = "OK"
        if warn_val != None and online_val <= warn_val:
            comp_state = "WARN"
        if crit_val != None and online_val <= crit_val:
            comp_state = "CRIT"
        if state == "OK" and comp_state != "OK":
            state = comp_state
        elif state == "WARN" and comp_state == "CRIT":
            state = "CRIT"
        total_str = " of " + str(total_val) if total_val != None else ""
        msgs.append("Online " + str(label) + ": " + str(online_val) + total_str)
        details.append("Online " + str(label) + ": " + str(online_val) + total_str)
        metric_name = "online_" + field
        online_metrics[metric_name] = online_val
    return state, msgs, details, online_metrics

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        version = params.get("version", "2c")
        base_oid = ".1.3.6.1.4.1.2.111.101.1.1"
        res = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, base_oid], mutates=False)
        if res.rc != 0 or res.skipped:
            return {"changed": False, "msg": "no IBM SVC enclosure data available", "data": {"discovery": []}}
        enclosures = _parse_snmp_enclosure_table(res.stdout)
        if len(enclosures) == 0:
            return {"changed": False, "msg": "no IBM SVC enclosures found", "data": {"discovery": []}}
        discovery = []
        for item, data in enclosures.items():
            metrics = _get_enclosure_metrics(data)
            discovery.append({"item": item, "params": {}, "metrics": metrics})
        return {"changed": False, "msg": "discovered %d enclosures" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    base_oid = ".1.3.6.1.4.1.2.111.101.1.1"
    res = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, base_oid], mutates=False)
    if res.rc != 0 or res.skipped or res.stdout == "":
        return {"changed": False, "msg": "no IBM SVC enclosure data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    enclosures = _parse_snmp_enclosure_table(res.stdout)
    data = enclosures.get(item)
    if data == None:
        return {"changed": False, "msg": "enclosure %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state, msgs, details, metrics = _grade_enclosure(data, params)
    return {"changed": False, "msg": "; ".join(msgs), "data": {"state": state, "metrics": metrics, "details": "\n".join(details)}}

def _get_enclosure_metrics(data):
    metrics = []
    for field, label in _COMPONENT_FIELDS:
        online_val = _try_int(data.get("online_" + field))
        if online_val != None:
            metrics.append("online_" + field)
    return metrics

def _parse_snmp_enclosure_table(stdout):
    enclosures = {}
    if stdout == None or stdout == "":
        return enclosures
    for line in stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1]
        idx_parts = oid.rsplit(".", 1)
        if len(idx_parts) != 2:
            continue
        idx = idx_parts[1]
        enclosures.setdefault(idx, {})["_idx"] = idx
        col = idx_parts[0].rsplit(".", 1)[1]
        enclosures[idx][col] = value
    result = {}
    for idx, cols in enclosures.items():
        item = cols.get("1", idx)
        row = {}
        for col_oid, val in cols.items():
            if col_oid == "_idx":
                continue
            field = _COLUMN_MAP.get(col_oid)
            if field != None:
                row[field] = val
        row["id"] = item
        result[item] = row
    return result

_COLUMN_MAP = {
    "2": "status",
    "3": "type",
    "4": "managed",
    "5": "IO_group_id",
    "6": "IO_group_name",
    "7": "product_MTM",
    "8": "serial_number",
    "9": "total_canisters",
    "10": "online_canisters",
    "11": "total_PSUs",
    "12": "online_PSUs",
    "13": "drive_slots",
    "14": "total_fan_modules",
    "15": "online_fan_modules",
    "16": "total_sems",
    "17": "online_sems",
}