def main(ctx, params):
    # Extract parameters with defaults
    database_name = params["database_name"]
    hostname = params.get("hostname", "localhost")
    password = params.get("password", "root")
    path = params.get("path", "")
    port = params.get("port", 8086)
    proxies = params.get("proxies", {})
    query = params["query"]
    retries = params.get("retries", 3)
    ssl = params.get("ssl", False)
    timeout = params.get("timeout")
    udp_port = params.get("udp_port", 4444)
    use_udp = params.get("use_udp", False)
    username = params.get("username", "root")
    validate_certs = params.get("validate_certs", True)

    # Validate required options
    if not query:
        fail("query is required")
    if not database_name:
        fail("database_name is required")

    # Build the InfluxDB HTTP URL
    scheme = "https" if ssl else "http"
    base_url = scheme + "://" + hostname + ":" + str(port)
    if path:
        base_url = base_url + "/" + path.lstrip("/")

    # Prepare the request payload for InfluxDB query endpoint
    payload = "db=" + database_name + "&q=" + query
    headers = ["Content-Type: application/x-www-form-urlencoded"]

    # Add authentication headers if credentials provided (not default root/root)
    if username != "root" or password != "root":
        headers.append("Authorization: Basic " + _base64_encode(username + ":" + password))

    # Build the curl command (no shell, direct args)
    curl_args = ["curl", "-s", "-X", "POST"]
    curl_args.append(base_url + "/query")
    curl_args.append("--data-binary")
    curl_args.append(payload)
    for header in headers:
        curl_args.extend(["-H", header])

    if not validate_certs:
        curl_args.append("-k")

    # Run the curl command (read-only operation)
    res = ctx.run(curl_args, mutates=False)
    if res.rc != 0:
        fail("query failed: " + res.stderr)

    # Parse JSON from stdout manually (no json module)
    results = _parse_influxdb_response(res.stdout)
    if results == None:
        fail("failed to parse InfluxDB response")

    return {
        "changed": True,
        "msg": "query executed successfully",
        "query_results": results
    }


# Helper: simple base64 encoding for Basic auth (no external deps)
def _base64_encode(s):
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    result = ""
    i = 0
    while i < len(s):
        # Get 3 bytes (or pad if不足)
        b1 = ord(s[i]) if i < len(s) else 0
        b2 = ord(s[i + 1]) if i + 1 < len(s) else 0
        b3 = ord(s[i + 2]) if i + 2 < len(s) else 0
        triplet = (b1 << 16) + (b2 << 8) + b3

        # Encode to 4 chars
        result += alphabet[(triplet >> 18) & 0x3F]
        result += alphabet[(triplet >> 12) & 0x3F]
        if i + 1 < len(s):
            result += alphabet[(triplet >> 6) & 0x3F]
        else:
            result += "="
        if i + 2 < len(s):
            result += alphabet[triplet & 0x3F]
        else:
            result += "="

        i += 3
    return result


# Helper: minimal JSON parser for InfluxDB response (list of dicts)
def _parse_influxdb_response(json_str):
    # Strip whitespace
    json_str = json_str.strip()
    if not json_str.startswith("{"):
        fail("unexpected InfluxDB response: not JSON object")

    # Find the "results" array index
    idx = json_str.find('"results"')
    if idx == -1:
        return []

    # Extract the array content after "results:"
    start = json_str.find("[", idx)
    if start == -1:
        return []

    # Find matching closing bracket
    depth = 0
    end = start
    in_string = False
    escape = False
    i = start
    while i < len(json_str):
        c = json_str[i]
        if escape:
            escape = False
            i += 1
            continue
        if c == "\\":
            escape = True
            i += 1
            continue
        if c == '"':
            in_string = not in_string
            i += 1
            continue
        if in_string:
            i += 1
            continue
        if c == '[':
            depth += 1
            i += 1
            continue
        if c == ']':
            depth -= 1
            if depth == 0:
                end = i
                break
        i += 1

    if depth != 0:
        fail("failed to parse JSON: unbalanced brackets")

    results_arr = json_str[start + 1:end]
    if results_arr == None:
        return []

    # Extract series items (naive approach)
    series_items = []
    depth = 0
    in_string = False
    escape = False
    segment_start = -1
    i = 0
    while i < len(results_arr):
        c = results_arr[i]
        if escape:
            escape = False
            i += 1
            continue
        if c == "\\":
            escape = True
            i += 1
            continue
        if c == '"':
            in_string = not in_string
            i += 1
            continue
        if in_string:
            i += 1
            continue
        if c == '[':
            depth += 1
            i += 1
            continue
        if c == ']':
            depth -= 1
            i += 1
            continue
        if c == '{' and depth == 0:
            segment_start = i
            i += 1
            continue
        if c == '}' and depth == 0 and segment_start >= 0:
            series_items.append(results_arr[segment_start:i + 1])
            segment_start = -1
            i += 1
            continue
        i += 1

    if not series_items:
        return []

    first_series = series_items[0] if series_items else ""
    if first_series == None:
        return []

    # Extract columns array
    cols_idx = first_series.find('"columns"')
    if cols_idx == -1:
        return []
    cols_arr_start = first_series.find("[", cols_idx)
    if cols_arr_start == -1:
        return []
    depth = 0
    cols_end = cols_arr_start
    in_string = False
    escape = False
    i = cols_arr_start
    while i < len(first_series):
        c = first_series[i]
        if escape:
            escape = False
            i += 1
            continue
        if c == "\\":
            escape = True
            i += 1
            continue
        if c == '"':
            in_string = not in_string
            i += 1
            continue
        if in_string:
            i += 1
            continue
        if c == '[':
            depth += 1
            i += 1
            continue
        if c == ']':
            depth -= 1
            if depth == 0:
                cols_end = i
                break
        i += 1
    cols_str = first_series[cols_arr_start + 1:cols_end]

    # Parse column names
    columns = []
    if cols_str != None:
        for item in cols_str.split(","):
            item = item.strip().strip('"')
            if item:
                columns.append(item)

    # Extract values array
    vals_idx = first_series.find('"values"')
    if vals_idx == -1:
        return []
    vals_arr_start = first_series.find("[", vals_idx)
    if vals_arr_start == -1:
        return []
    depth = 0
    vals_end = vals_arr_start
    in_string = False
    escape = False
    i = vals_arr_start
    while i < len(first_series):
        c = first_series[i]
        if escape:
            escape = False
            i += 1
            continue
        if c == "\\":
            escape = True
            i += 1
            continue
        if c == '"':
            in_string = not in_string
            i += 1
            continue
        if in_string:
            i += 1
            continue
        if c == '[':
            depth += 1
            i += 1
            continue
        if c == ']':
            depth -= 1
            if depth == 0:
                vals_end = i
                break
        i += 1
    vals_str = first_series[vals_arr_start + 1:vals_end]

    # Parse values into rows
    rows = []
    i = 0
    while i < len(vals_str):
        while i < len(vals_str) and vals_str[i] == ' ':
            i += 1
        if i >= len(vals_str):
            break
        if vals_str[i] == '[':
            row_start = i
            depth = 1
            i += 1
            while i < len(vals_str) and depth > 0:
                if vals_str[i] == '[':
                    depth += 1
                elif vals_str[i] == ']':
                    depth -= 1
                i += 1
            if depth == 0:
                rows.append(vals_str[row_start:i])
        else:
            i += 1

    # Build result list
    results = []
    for row in rows:
        # Parse row into list of values
        values = _parse_row_values(row)
        if len(values) == len(columns):
            row_dict = {}
            for i in range(len(columns)):
                row_dict[columns[i]] = values[i]
            results.append(row_dict)

    return results


def _parse_row_values(row):
    # Remove surrounding brackets
    if row == None or len(row) < 2 or row[0] != '[' or row[-1] != ']':
        return []
    row = row[1:-1]
    values = []
    i = 0
    while i < len(row):
        while i < len(row) and row[i] == ' ':
            i += 1
        if i >= len(row):
            break
        if row[i] == '"':
            # Quoted string
            j = i + 1
            while j < len(row) and row[j] != '"':
                if row[j] == '\\' and j + 1 < len(row):
                    j += 2
                else:
                    j += 1
            if j < len(row):
                s = row[i + 1:j]
                # Unescape
                s = s.replace('\\"', '"').replace('\\\\', '\\')
                values.append(s)
                i = j + 1
            else:
                i += 1
        else:
            # Number or null
            j = i
            while j < len(row) and row[j] not in ', ]':
                j += 1
            token = row[i:j].strip()
            if token == 'null' or token == '':
                values.append(None)
            elif token.startswith('"'):
                values.append(token.strip('"'))
            else:
                # Try convert to int or float
                if '.' in token:
                    values.append(float(token))
                else:
                    values.append(int(token))
            i = j

    return values
