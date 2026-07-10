def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command = params["command"]
    username = params["username"]
    password = params["password"]
    timeout = params.get("timeout", 10)
    job_name = params.get("job_name")
    proxy_slot_number = params.get("proxy_slot_number")

    CATEGORY_COMMANDS_ALL = {
        "Jobs": ["JobStatus"]
    }

    if category not in CATEGORY_COMMANDS_ALL:
        fail("Invalid Category '%s'. Valid Categories = %s" % (category, list(CATEGORY_COMMANDS_ALL.keys())))

    if command not in CATEGORY_COMMANDS_ALL[category]:
        fail("Invalid Command '%s'. Valid Commands = %s" % (command, CATEGORY_COMMANDS_ALL[category]))

    base_uri = "https://" + baseuri

    # Build job URI if needed
    job_uri = None
    if category == "Jobs" and command == "JobStatus":
        if job_name == None:
            fail("job_name required for JobStatus command.")
        job_uri = base_uri + "/Jobs/" + job_name

    # For JobStatus, we simulate the ocapi_utils.get_job_status behavior using direct HTTP calls
    # Since ctx does not provide HTTP helpers, we use ctx.run to call curl
    # We assume curl is available in the environment
    auth = username + ":" + password
    headers = ["-H", "Content-Type: application/json"]

    # Check mode: predict result without making real request
    if ctx.check_mode:
        if category == "Jobs" and command == "JobStatus":
            return {
                "changed": False,
                "msg": "No action performed in check mode.",
                "ret": False,
                "msg": "Job status fetch would be performed in check mode.",
                "percentComplete": 0,
                "operationStatus": "Unknown",
                "operationStatusId": 0,
                "operationHealth": "Unknown",
                "operationHealthId": 0,
                "details": ["Check mode — no data fetched"],
                "status": {
                    "Details": ["Check mode"],
                    "Health": [{"ID": 0, "Name": "Unknown"}],
                    "State": {"ID": 0, "Name": "Unknown"}
                }
            }
        return {"changed": False, "msg": "No action performed in check mode."}

    # Execute JobStatus command
    if category == "Jobs" and command == "JobStatus" and job_uri != None:
        curl_argv = [
            "curl", "-s", "-k",
            "-u", auth,
            "-H", "Content-Type: application/json",
            "-X", "GET",
            "--connect-timeout", str(timeout),
            job_uri
        ]
        res = ctx.run(curl_argv)
        if res.rc != 0:
            fail("JobStatus command failed: " + res.stderr)
        # Parse JSON manually (no json module) using basic string parsing
        output = res.stdout
        # Simple JSON extraction for expected fields — fallbacks provided
        def extract_str(key):
            # Look for "key": "value"
            idx = output.find('"' + key + '"')
            if idx == -1:
                return None
            start = output.find(':', idx)
            if start == -1:
                return None
            start += 1
            while start < len(output) and output[start] in " \t\n":
                start += 1
            if start >= len(output) or output[start] != '"':
                return None
            start += 1
            end = output.find('"', start)
            if end == -1:
                return None
            return output[start:end]

        def extract_int(key):
            idx = output.find('"' + key + '"')
            if idx == -1:
                return None
            start = output.find(':', idx)
            if start == -1:
                return None
            start += 1
            while start < len(output) and output[start] in " \t\n":
                start += 1
            num_start = start
            while start < len(output) and output[start].isdigit():
                start += 1
            if start == num_start:
                return None
            return int(output[num_start:start])

        def extract_list(key):
            # Look for "key": ["value", ...]
            idx = output.find('"' + key + '"')
            if idx == -1:
                return None
            start = output.find(':', idx)
            if start == -1:
                return None
            start += 1
            while start < len(output) and output[start] in " \t\n":
                start += 1
            if start >= len(output) or output[start] != '[':
                return None
            start += 1
            end = output.find(']', start)
            if end == -1:
                return None
            inner = output[start:end]
            # Split by "," and strip quotes
            items = []
            for item in inner.split(","):
                item = item.strip().strip('"')
                if item != "":
                    items.append(item)
            return items

        def extract_dict(key):
            # Look for "key": { ... }
            idx = output.find('"' + key + '"')
            if idx == -1:
                return None
            start = output.find(':', idx)
            if start == -1:
                return None
            start += 1
            while start < len(output) and output[start] in " \t\n":
                start += 1
            if start >= len(output) or output[start] != '{':
                return None
            # Find matching brace
            depth = 1
            end = start + 1
            while end < len(output) and depth > 0:
                if output[end] == '{':
                    depth += 1
                elif output[end] == '}':
                    depth -= 1
                end += 1
            if depth != 0:
                return None
            inner = output[start+1:end-1]
            # Parse simple { "key": value, ... }
            result_dict = {}
            parts = inner.split(",")
            for part in parts:
                part = part.strip()
                if part == "":
                    continue
                colon = part.find(":")
                if colon == -1:
                    continue
                k = part[:colon].strip().strip('"')
                v_raw = part[colon+1:].strip()
                if v_raw.startswith('"'):
                    # string value
                    v = v_raw[1:v_raw.rfind('"')]
                elif v_raw.isdigit():
                    v = int(v_raw)
                else:
                    v = v_raw  # fallback
                result_dict[k] = v
            return result_dict

        # Extract fields
        percentComplete = extract_int("PercentComplete")
        operationStatus = extract_str("OperationStatus")
        operationStatusId = extract_int("OperationStatusId")
        operationHealth = extract_str("OperationHealth")
        operationHealthId = extract_int("OperationHealthId")
        details = extract_list("Details")
        status_dict = extract_dict("Status")

        # Build return dict
        result = {
            "changed": False,
            "msg": "Action was successful.",
            "percentComplete": percentComplete if percentComplete != None else 0,
            "operationStatus": operationStatus if operationStatus != None else "Unknown",
            "operationStatusId": operationStatusId if operationStatusId != None else 0,
            "operationHealth": operationHealth if operationHealth != None else "Unknown",
            "operationHealthId": operationHealthId if operationHealthId != None else 0,
            "details": details if details != None else [],
            "status": status_dict if status_dict != None else {}
        }
        return result

    fail("Unsupported category/command combination")
