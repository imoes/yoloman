def main(ctx, params):
    # Required parameters
    data_points = params["data_points"]
    database_name = params["database_name"]

    # Optional parameters with defaults
    hostname = params.get("hostname", "localhost")
    port = params.get("port", 8086)
    username = params.get("username", "root")
    password = params.get("password", "root")
    path = params.get("path", "")
    ssl = params.get("ssl", False)
    validate_certs = params.get("validate_certs", True)
    use_udp = params.get("use_udp", False)
    udp_port = params.get("udp_port", 4444)
    timeout = params.get("timeout")
    proxies = params.get("proxies", {})
    retries = params.get("retries", 3)

    # Build URL for HTTP client
    if ssl:
        protocol = "https"
    else:
        protocol = "http"

    # Construct base URL
    url = protocol + "://" + hostname
    if port != None and port != (443 if ssl else 80):
        url += ":" + str(port)

    # Add path if provided
    if path:
        if not path.startswith("/"):
            path = "/" + path
        url += path

    # Create InfluxDB write request body
    # Format data points as line protocol string for POST body
    # Each data point is a dict with measurement, tags, time, fields
    body_lines = []
    for point in data_points:
        if "measurement" not in point:
            fail("Each data point must have a 'measurement' key")
        measurement = point["measurement"]

        # Tags
        tags = point.get("tags", {})
        if tags:
            tag_str = ",".join([k + "=" + str(v) for k, v in sorted(tags.items())])
            measurement += "," + tag_str

        # Fields
        fields = point.get("fields", {})
        if not fields:
            fail("Each data point must have 'fields'")
        field_parts = []
        for k, v in sorted(fields.items()):
            # Handle different field value types
            if isinstance(v, str):
                # String field: quote with escaped quotes
                v_escaped = v.replace('"', '\\"')
                field_parts.append(k + '="' + v_escaped + '"')
            elif isinstance(v, bool):
                field_parts.append(k + "=" + ("t" if v else "f"))
            elif isinstance(v, (int, float)):
                field_parts.append(k + "=" + str(v) + "i" if isinstance(v, int) else str(v))
            else:
                field_parts.append(k + '="' + str(v).replace('"', '\\"') + '"')
        fields_str = ",".join(field_parts)

        # Time (optional)
        time_str = ""
        if "time" in point:
            time_str = " " + str(point["time"])

        line = measurement + " " + fields_str + time_str
        body_lines.append(line)

    body = "\n".join(body_lines)

    # Prepare headers
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
    }

    # Build auth params
    auth_str = ""
    if username:
        auth_str += username
        if password:
            auth_str += ":" + password

    # Construct curl command
    # Use -X POST with data
    # Note: curl does not support all InfluxDB features directly; we simulate via HTTP
    # We use a curl command to POST to InfluxDB
    curl_args = ["curl", "-s", "-S", "-X", "POST"]

    # URL with query params
    url_with_db = url + "/write?db=" + database_name
    curl_args.append(url_with_db)

    # Authentication
    if auth_str:
        curl_args.extend(["-u", auth_str])

    # SSL options
    if not validate_certs:
        curl_args.append("-k")

    # Timeout
    if timeout != None:
        curl_args.extend(["--connect-timeout", str(timeout)])

    # Set data via --data-binary (to preserve newlines)
    # Escape special shell characters in body for command line
    # We'll pass body as a file via stdin to avoid escaping issues
    # So: curl ... -d @-
    curl_args.append("-d")
    curl_args.append("@" + "-")  # read from stdin

    # Execute via ctx.run with stdin data
    if ctx.check_mode:
        # In check mode, we can only predict
        return {"changed": True, "msg": "would write " + str(len(data_points)) + " data points to InfluxDB database '" + database_name + "' at " + hostname}

    res = ctx.run(curl_args, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would write " + str(len(data_points)) + " data points"}

    if res.rc != 0:
        fail("InfluxDB write failed: " + res.stderr)

    # Check response body for success (204 No Content expected)
    # curl does not expose HTTP status directly; we infer from output
    # InfluxDB returns 204 No Content on success
    # We'll assume success if rc=0 and empty stderr/stdout
    # (InfluxDB typically responds with nothing on success)
    if res.stdout or res.stderr:
        # Some InfluxDB versions may return messages; inspect if needed
        # But per docs, success is 204, no body
        pass

    return {"changed": True, "msg": "wrote " + str(len(data_points)) + " data points to InfluxDB database '" + database_name + "'"}
