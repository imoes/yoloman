def _parse_db2_dbs(string_table):
    current_instance = None
    dbs = {}
    global_timestamp = None
    for line in string_table:
        if len(line) < 1:
            continue
        if line[0].startswith("TIMESTAMP") and current_instance == None:
            if len(line) >= 2:
                global_timestamp = int(line[1])
            continue
        if line[0].startswith("[[["):
            current_instance = line[0][3:-3]
            dbs[current_instance] = []
        elif current_instance != None:
            dbs[current_instance].append(line)
    return global_timestamp, dbs


def _parse_db2_bp_hitratios(string_table):
    _pre_parsed = _parse_db2_dbs(string_table)
    databases = {}
    instance_lines = _pre_parsed[1]
    for instance, lines in instance_lines.items():
        header_idx = None
        node_names = []
        node_headers = []
        for idx in range(len(lines)):
            line = lines[idx]
            if len(line) >= 1 and line[0] == "node":
                node_names.append(" ".join(line[1:]))
            elif len(line) >= 1 and line[0] == "BP_NAME":
                header_idx = idx
                node_headers = line
                break
        if len(node_names) > 0:
            if header_idx == None:
                continue
            current_node_offset = -1
            current_instance = None
            for line in lines[header_idx + 1:]:
                if len(line) >= 1 and line[0] == "IBMDEFAULTBP":
                    current_node_offset += 1
                    current_instance = instance + " DPF " + node_names[current_node_offset]
                    if current_instance not in databases:
                        databases[current_instance] = [node_headers]
                if current_instance in databases:
                    databases[current_instance].append(line)
        else:
            databases[instance] = lines
    return databases


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["db2pd", "-dbs"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "db2 not installed", "data": {"discovery": []}}
        out = []
        string_table = []
        for raw_line in res.stdout.splitlines():
            if raw_line == "":
                continue
            fields = raw_line.split()
            if len(fields) > 0 and fields[0].startswith("[[["):
                string_table.append([raw_line])
            else:
                string_table.append(fields)
        if len(string_table) == 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        section = _parse_db2_bp_hitratios(string_table)
        for key, values in section.items():
            if len(values) < 2:
                continue
            for field in values[1:]:
                if len(field) < 1:
                    continue
                if not field[0].startswith("IBMSYSTEMBP"):
                    out.append({"item": key + ":" + field[0], "params": {}, "metrics": ["totalratio", "dataratio", "indexratio", "xdaratio"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    db_instance, field = item.rsplit(":", 1)
    res = ctx.run(["db2pd", "-dbs"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "db2 not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": "db2 not installed"}}
    string_table = []
    for raw_line in res.stdout.splitlines():
        if raw_line == "":
            continue
        fields = raw_line.split()
        if len(fields) > 0 and fields[0].startswith("[[["):
            string_table.append([raw_line])
        else:
            string_table.append(fields)
    if len(string_table) == 0:
        return {"changed": False, "msg": "no db2 data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no db2 data available"}}
    section = _parse_db2_bp_hitratios(string_table)
    db = section.get(db_instance)
    if db == None:
        return {"changed": False, "msg": "database instance not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "database instance " + db_instance + " not found"}}
    headers = db[0]
    metrics = {}
    details_parts = []
    for line in db[1:]:
        if len(line) < 1:
            continue
        if field != line[0]:
            continue
        hr_info = {}
        for i in range(1, len(headers)):
            if i < len(line):
                hr_info[headers[i]] = line[i]
        for header in headers[1:]:
            raw_val = hr_info.get(header, "-")
            value = raw_val.replace("-", "0").replace(",", ".")
            key = header.replace("_RATIO_PERCENT", "")
            float_value = float(value)
            metric_name = key.lower() + "ratio"
            metrics[metric_name] = float_value
            details_parts.append(key + ": " + value + "%")
        break
    if len(metrics) == 0:
        return {"changed": False, "msg": "bufferpool not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "bufferpool " + field + " not found"}}
    summary = ", ".join(details_parts)
    return {"changed": False, "msg": summary, "data": {"state": "OK", "metrics": metrics, "details": summary}}