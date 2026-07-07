def main(ctx, params):
    # Required parameters
    api_key = params["api_key"]
    app_key = params["app_key"]
    title = params["title"]
    text = params["text"]

    # Optional parameters with defaults
    date_happened = params.get("date_happened", None)
    priority = params.get("priority", "normal")
    host = params.get("host", None)
    tags = params.get("tags", None)
    alert_type = params.get("alert_type", "info")
    aggregation_key = params.get("aggregation_key", None)
    validate_certs = params.get("validate_certs", True)
    api_host = params.get("api_host", None)

    # Host fallback to system hostname if not provided
    if host == None:
        facts = ctx.facts()
        host = facts.get("hostname", "").split(".")[0]

    # Build tags list as comma-separated string (original module accepts both list and str)
    tags_str = None
    if tags != None:
        if isinstance(tags, list):
            tag_parts = []
            for t in tags:
                if t != None:
                    tag_parts.append(str(t))
            tags_str = ",".join(tag_parts)
        else:
            tags_str = str(tags)

    # Build the curl command arguments
    curl_args = ["curl", "--silent", "--show-error", "--location"]

    # SSL verification
    if not validate_certs:
        curl_args.extend(["--insecure"])

    # API host
    base_url = api_host if api_host != None else "https://api.datadoghq.com"
    endpoint = base_url + "/api/v1/events"

    # Headers (standard for Datadog API)
    curl_args.extend([
        "--request", "POST",
        "--header", "Content-Type: application/json",
        "--header", "DD-API-KEY: " + api_key,
        "--header", "DD-APPLICATION-KEY: " + app_key,
    ])

    # JSON body construction (use ctx.run to build JSON safely)
    # Build JSON string manually (no json module available)
    # Escape double quotes and backslashes in strings
    def escape_json_string(s):
        return str(s).replace("\\", "\\\\").replace('"', '\\"')

    body_parts = []
    body_parts.append('{"title": "' + escape_json_string(title) + '",')
    body_parts.append('"text": "' + escape_json_string(text) + '",')
    body_parts.append('"host": "' + escape_json_string(host) + '"')

    if date_happened != None:
        body_parts.append(',"date_happened": ' + str(int(date_happened)))

    if priority != None:
        body_parts.append(',"priority": "' + priority + '"')

    if alert_type != None:
        body_parts.append(',"alert_type": "' + alert_type + '"')

    if tags_str != None:
        # Convert comma-separated tags to JSON array of strings
        tag_list = []
        for t in tags_str.split(","):
            if t.strip():
                tag_list.append('"' + escape_json_string(t.strip()) + '"')
        body_parts.append(',"tags": [' + ",".join(tag_list) + ']')

    if aggregation_key != None:
        body_parts.append(',"aggregation_key": "' + escape_json_string(aggregation_key) + '"')

    body_parts.append(',"source_type_name": "ansible"}')

    curl_args.extend([
        "--data", "".join(body_parts),
        endpoint,
    ])

    # Execute the request (mutates = true since it writes an event)
    res = ctx.run(curl_args, mutates=True, ok_codes=[0])

    if res.skipped:
        # Check mode: would post an event
        return {"changed": True, "msg": "would post event to Datadog"}

    if res.rc != 0:
        fail("failed to post event: " + res.stderr)

    # Parse response JSON manually (no json module)
    # Look for status field in response
    stdout = res.stdout.strip()
    if '"status":"ok"' not in stdout and '"status": "ok"' not in stdout:
        fail("unexpected response from Datadog API: " + stdout)

    return {"changed": True, "msg": "event posted to Datadog"}
