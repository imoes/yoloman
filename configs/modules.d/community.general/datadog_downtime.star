def main(ctx, params):
    api_key = params.get("api_key")
    app_key = params.get("app_key")
    api_host = params.get("api_host", "https://api.datadoghq.com")
    state = params.get("state", "present")
    downtime_id = params.get("id")

    if not api_key or not app_key:
        fail("api_key and app_key are required")

    # Helper to build HTTP command arguments for curl
    def make_curl_args(method, path, body=None):
        url = api_host.rstrip("/") + path
        base = ["curl", "-sS", "-X", method]
        headers_list = [
            "DD-API-KEY: " + api_key,
            "DD-APPLICATION-KEY: " + app_key,
            "Content-Type: application/json",
        ]
        for h in headers_list:
            base.extend(["-H", h])
        if body != None:
            base.extend(["-d", body])
        base.append(url)
        return base

    # Helper to make HTTP requests
    def http(method, path, body=None):
        argv = make_curl_args(method, path, body)
        res = ctx.run(argv, mutates=(method != "GET"))
        if res.skipped:
            return res  # check_mode
        if res.rc != 0:
            fail("HTTP " + method + " failed: " + res.stderr)
        return res

    # Get downtime by id
    def get_downtime(downtime_id):
        if downtime_id == None:
            return None
        res = http("GET", "/api/v1/downtime/" + str(downtime_id))
        if res.rc != 0:
            fail("Failed to retrieve downtime " + str(downtime_id) + ": " + res.stderr)
        stdout = res.stdout.strip()
        if stdout == "" or stdout == "{}":
            return None
        return stdout

    # Build downtime payload
    payload_parts = []
    if params.get("monitor_tags"):
        tags = params["monitor_tags"]
        escaped_tags = []
        for t in tags:
            escaped = t.replace("\\", "\\\\").replace('"', '\\"')
            escaped_tags.append('"' + escaped + '"')
        payload_parts.append('"monitor_tags":[' + ",".join(escaped_tags) + "]")
    if params.get("scope"):
        scopes = params["scope"]
        escaped_scopes = []
        for s in scopes:
            escaped = s.replace("\\", "\\\\").replace('"', '\\"')
            escaped_scopes.append('"' + escaped + '"')
        payload_parts.append('"scope":[' + ",".join(escaped_scopes) + "]")
    if params.get("monitor_id") != None:
        payload_parts.append('"monitor_id":' + str(params["monitor_id"]))
    if params.get("downtime_message"):
        msg = params["downtime_message"]
        escaped = msg.replace("\\", "\\\\").replace('"', '\\"')
        payload_parts.append('"message":"' + escaped + '"')
    if params.get("start") != None:
        payload_parts.append('"start":' + str(params["start"]))
    if params.get("end") != None:
        payload_parts.append('"end":' + str(params["end"]))
    if params.get("timezone"):
        tz = params["timezone"]
        escaped = tz.replace("\\", "\\\\").replace('"', '\\"')
        payload_parts.append('"timezone":"' + escaped + '"')
    if params.get("rrule"):
        rrule = params["rrule"]
        escaped = rrule.replace("\\", "\\\\").replace('"', '\\"')
        payload_parts.append('"recurrence":{"rrule":"' + escaped + '","type":"rrule"}')

    payload = "{" + ",".join(payload_parts) + "}"

    # Present state: create or update
    if state == "present":
        current = get_downtime(downtime_id)
        if current == None:
            # Create new downtime
            if ctx.check_mode:
                return {"changed": True, "msg": "would create downtime"}
            res = http("POST", "/api/v1/downtime", payload)
            # Extract downtime ID from JSON response (simple scan)
            stdout = res.stdout
            idx = stdout.find('"id":')
            if idx == -1:
                fail("Could not extract downtime id from response")
            start = idx + 5
            end = start
            while end < len(stdout) and stdout[end].isdigit():
                end += 1
            if start == end:
                fail("Could not parse downtime id from response")
            created_id = int(stdout[start:end])
            return {
                "changed": True,
                "msg": "downtime created",
                "data": {"id": created_id},
            }
        else:
            # Update existing downtime
            if ctx.check_mode:
                return {"changed": True, "msg": "would update downtime"}
            res = http("PUT", "/api/v1/downtime/" + str(downtime_id), payload)
            return {"changed": True, "msg": "downtime updated"}

    # Absent state: delete downtime
    elif state == "absent":
        if downtime_id == None:
            fail("id is required when state=absent")
        current = get_downtime(downtime_id)
        if current == None:
            return {"changed": False, "msg": "downtime not found"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete downtime"}
        res = http("DELETE", "/api/v1/downtime/" + str(downtime_id))
        return {"changed": True, "msg": "downtime deleted"}

    fail("Unsupported state: " + state)
