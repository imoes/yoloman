def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["db2", "list", "bufferpools", "show details"], mutates=False)
        lines = res.stdout.splitlines()
        current_instance = None
        section = {}
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("[[[") and stripped.endswith("]]]"):
                current_instance = stripped[3:-3]
                section[current_instance] = []
            elif current_instance != None and stripped != "":
                fields = stripped.split()
                section[current_instance].append(fields)

        # Parse section like the Checkmk source does
        pre_parsed = {}
        for inst, flines in section.items():
            if not flines:
                continue
            pre_parsed[inst] = flines

        databases = {}
        for instance, lines in pre_parsed.items():
            header_idx = None
            node_names = []
            node_headers = []
            for idx, line in enumerate(lines):
                if len(line) > 0 and line[0] == "node":
                    node_names.append(" ".join(line[1:]))
                elif len(line) > 0 and line[0] == "BP_NAME":
                    header_idx = idx
                    node_headers = line
                    break

            if node_names:
                if header_idx == None:
                    continue
                current_node_offset = -1
                current_instance = None
                for line in lines[header_idx + 1:]:
                    if len(line) > 0 and line[0] == "IBMDEFAULTBP":
                        current_node_offset = current_node_offset + 1
                        current_instance = "%s DPF %s" % (instance, node_names[current_node_offset])
                        databases.setdefault(current_instance, [node_headers])
                    if current_instance in databases:
                        databases[current_instance].append(line)
            else:
                databases[instance] = lines

        # Discovery: skip IBMSYSTEMBP items
        out = []
        for key, values in databases.items():
            if len(values) < 2:
                continue
            for field in values[1:]:
                if len(field) > 0 and not field[0].startswith("IBMSYSTEMBP"):
                    item = "%s:%s" % (key, field[0])
                    out.append({"item": item, "params": {}, "metrics": ["totalratio", "dataratio", "indexratio", "xdaratio"]})

        return {"changed": False, "msg": "discovered %d bufferpools" % len(out), "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["db2", "list", "bufferpools", "show details"], mutates=False)
    lines = res.stdout.splitlines()

    current_instance = None
    section = {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[[[") and stripped.endswith("]]]"):
            current_instance = stripped[3:-3]
            section[current_instance] = []
        elif current_instance != None and stripped != "":
            fields = stripped.split()
            section[current_instance].append(fields)

    # Parse like Checkmk
    pre_parsed = {}
    for inst, flines in section.items():
        if not flines:
            continue
        pre_parsed[inst] = flines

    databases = {}
    for instance, lines in pre_parsed.items():
        header_idx = None
        node_names = []
        node_headers = []
        for idx, line in enumerate(lines):
            if len(line) > 0 and line[0] == "node":
                node_names.append(" ".join(line[1:]))
            elif len(line) > 0 and line[0] == "BP_NAME":
                header_idx = idx
                node_headers = line
                break

        if node_names:
            if header_idx == None:
                continue
            current_node_offset = -1
            current_instance = None
            for line in lines[header_idx + 1:]:
                if len(line) > 0 and line[0] == "IBMDEFAULTBP":
                    current_node_offset = current_node_offset + 1
                    current_instance = "%s DPF %s" % (instance, node_names[current_node_offset])
                    databases.setdefault(current_instance, [node_headers])
                if current_instance in databases:
                    databases[current_instance].append(line)
        else:
            databases[instance] = lines

    # Try to find requested item
    key = item.rsplit(":", 1)
    if len(key) != 2:
        return {"changed": False, "msg": "invalid item format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    db_instance = key[0]
    field = key[1]
    db = databases.get(db_instance)
    if db == None:
        return {"changed": False, "msg": "database instance not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    headers = db[0]
    found = False
    metrics = {}
    summaries = []
    for line in db[1:]:
        if field != line[0]:
            continue
        if len(headers) < 2 or len(line) < 2:
            break
        found = True
        hr_info = {}
        for i in range(1, min(len(headers), len(line))):
            hr_info[headers[i]] = line[i]
        key_to_text = {
            "TOTAL_HIT": "Total",
            "DATA_HIT": "Data",
            "INDEX_HIT": "Index",
            "XDA_HIT": "XDA",
        }
        for header in headers[1:]:
            value_raw = hr_info.get(header, "-")
            value_str = value_raw.replace("-", "0").replace(",", ".")
            key_name = header.replace("_RATIO_PERCENT", "")
            # Safe float conversion without try/except
            if value_str == "0" or value_str.find("-") >= 0 or value_str.find(".") >= 0:
                clean = value_str.replace(".", "").replace("-", "")
                if clean.isdigit():
                    float_value = float(value_str)
                else:
                    float_value = 0.0
            elif value_str.isdigit():
                float_value = float(value_str)
            else:
                float_value = 0.0
            summaries.append("%s: %s%%" % (key_to_text.get(key_name, key_name), value_str))
            metrics[key_name.lower() + "ratio"] = float_value
        break

    if not found:
        return {"changed": False, "msg": "bufferpool not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": ", ".join(summaries), "data": {"state": "OK", "metrics": metrics, "details": ""}}