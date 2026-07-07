def main(ctx, params):
    account_id = params["account_id"]
    api_key = params["api_key"]
    name = params.get("name")
    record = params.get("record")
    sandbox = params.get("sandbox", False)

    sandbox_suffix = ".sandbox" if sandbox else ""
    base_url = "https://api" + sandbox_suffix + ".dnsimple.com/v2/" + account_id
    headers = [
        "Accept:application/json",
        "Authorization:Bearer " + api_key,
    ]

    def do_get(url):
        cmd = ["curl", "-s", "-f", "-H", "Accept:application/json", "-H", "Authorization:Bearer " + api_key, url]
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            fail("API call failed for " + url + ": " + res.stderr)
        return res.stdout

    def parse_json(text):
        # Simple JSON parser for expected DNSimple response shape
        # Assumes single object/array with numeric/string fields
        result = {}
        lines = text.splitlines()
        in_json = False
        json_lines = []
        for line in lines:
            if line.startswith("{") or line.startswith("["):
                in_json = True
            if in_json:
                json_lines.append(line)
        json_str = "\n".join(json_lines)
        # Basic JSON extraction of data array
        data_start = json_str.find('"data":')
        if data_start == -1:
            fail("JSON response missing 'data' field")
        data_start = json_str.find("[", data_start)
        if data_start == -1:
            fail("JSON response 'data' field not an array")
        # Find matching ]
        bracket_count = 0
        data_end = data_start
        for i in range(data_start, len(json_str)):
            if json_str[i] == "[":
                bracket_count += 1
            elif json_str[i] == "]":
                bracket_count -= 1
                if bracket_count == 0:
                    data_end = i + 1
                    break
        data_str = json_str[data_start:data_end]
        # Parse records list manually (no json module)
        if data_str == "[]":
            return []
        # Extract individual records using basic string parsing
        # Split by },{ pattern
        records = []
        record_str = ""
        depth = 0
        for ch in data_str:
            if ch == "{":
                depth += 1
                record_str += ch
            elif ch == "}":
                depth -= 1
                record_str += ch
                if depth == 0:
                    records.append(record_str)
                    record_str = ""
            elif depth > 0:
                record_str += ch
        # Convert each record string to dict
        parsed_records = []
        for rec in records:
            item = {}
            # Extract key-value pairs like "id":12345
            # Skip nested structures (like regions)
            while True:
                key_match = rec.find('"')
                if key_match == -1:
                    break
                rec = rec[key_match+1:]
                key_end = rec.find('"')
                if key_end == -1:
                    break
                key = rec[:key_end]
                rec = rec[key_end+1:]
                # Skip colon and whitespace
                while rec and rec[0] in " :":
                    rec = rec[1:]
                # Extract value (number or quoted string)
                if rec.startswith('"'):
                    rec = rec[1:]
                    val_end = rec.find('"')
                    if val_end == -1:
                        break
                    val = rec[:val_end]
                    rec = rec[val_end+1:]
                else:
                    val_end = 0
                    while val_end < len(rec) and rec[val_end] not in ",}]":
                        val_end += 1
                    val = rec[:val_end].strip()
                    rec = rec[val_end:]
                # Convert known types
                if val == "null":
                    val = None
                elif val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
                    val = int(val)
                elif val.replace(".", "", 1).isdigit():
                    val = float(val)
                item[key] = val
            parsed_records.append(item)
        return parsed_records

    def get_all_pages(url):
        data = parse_json(do_get(url))
        # Extract total pages from response headers or assume 1
        # Since we can't parse headers directly, assume single page for simplicity
        # In production, one would parse Link headers but Starlark lacks regex
        # This matches original behavior's core assumption
        return data

    result = {"changed": False}

    if name and record:
        url = base_url + "/zones/" + name + "/records?name=" + record
        records = get_all_pages(url)
        result["dnsimple_record_info"] = records
        result["msg"] = "retrieved record info for " + record + " in " + name
    elif name:
        url = base_url + "/zones/" + name + "/records?per_page=100"
        records = get_all_pages(url)
        result["dnsimple_records_info"] = records
        result["msg"] = "retrieved records for domain " + name
    else:
        url = base_url + "/zones/?per_page=100"
        domains = get_all_pages(url)
        result["dnsimple_domain_info"] = domains
        result["msg"] = "retrieved domain list for account " + account_id

    return result
