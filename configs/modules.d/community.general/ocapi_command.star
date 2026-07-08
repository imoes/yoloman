def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command = params["command"]
    username = params["username"]
    password = params["password"]
    timeout = params.get("timeout", 10)
    job_name = params.get("job_name")
    update_image_path = params.get("update_image_path")
    proxy_slot_number = params.get("proxy_slot_number")

    CATEGORY_COMMANDS_ALL = {
        "Chassis": ["IndicatorLedOn", "IndicatorLedOff", "PowerModeLow", "PowerModeNormal"],
        "Systems": ["PowerGracefulRestart"],
        "Update": ["FWUpload", "FWUpdate", "FWActivate"],
        "Jobs": ["DeleteJob"]
    }
    
    if category not in CATEGORY_COMMANDS_ALL:
        fail("Invalid Category '%s'. Valid Categories = %s" % (category, str(list(CATEGORY_COMMANDS_ALL.keys()))))
    
    if command not in CATEGORY_COMMANDS_ALL[category]:
        fail("Invalid Command '%s'. Valid Commands = %s" % (command, str(CATEGORY_COMMANDS_ALL[category])))

    base_uri = "https://%s" % baseuri

    path = ""
    payload = None
    method = ""
    
    if category == "Chassis":
        if command.startswith("IndicatorLed"):
            path = "/Chassis"
            payload = {"IndicatorLed": "On" if command == "IndicatorLedOn" else "Off"}
            method = "PATCH"
        elif command.startswith("PowerMode"):
            path = "/Chassis"
            payload = {"PowerMode": "Low" if command == "PowerModeLow" else "Normal"}
            method = "PATCH"
    elif category == "Systems":
        if command.startswith("Power"):
            path = "/Systems"
            if command == "PowerGracefulRestart":
                payload = {"Action": "GracefulRestart"}
                method = "POST"
            else:
                fail("Unsupported Power command: " + command)
    elif category == "Update":
        if command == "FWUpload":
            if update_image_path == None:
                fail("Missing update_image_path.")
            path = "/Update"
            method = "POST"
        elif command == "FWUpdate":
            path = "/Update"
            payload = {"Action": "FWUpdate"}
            method = "POST"
        elif command == "FWActivate":
            path = "/Update"
            payload = {"Action": "FWActivate"}
            method = "POST"
    elif category == "Jobs":
        if command == "DeleteJob":
            if job_name == None:
                fail("Missing job_name.")
            path = "/Jobs/" + job_name
            method = "DELETE"
        else:
            fail("Unsupported Jobs command: " + command)

    url = base_uri + path

    # Build JSON payload string
    payload_str = ""
    if payload != None:
        # Minimal JSON encoding (no external libraries)
        items = []
        for k in payload:
            v = payload[k]
            if type(v) == "bool" or type(v) == "int":
                items.append('"%s": %s' % (k, str(v).lower() if type(v) == "bool" else str(v)))
            else:
                items.append('"%s": "%s"' % (k, str(v)))
        payload_str = "{" + ", ".join(items) + "}"

    # Handle check mode
    if ctx.check_mode:
        if command == "FWUpload":
            return {
                "changed": True,
                "msg": "would upload firmware image to " + base_uri
            }
        return {
            "changed": True,
            "msg": "would execute " + command + " on " + category
        }

    # Execute command
    headers = ["-H", "Content-Type: application/json", "-u", username + ":" + password]
    
    if command == "FWUpload":
        # For firmware upload, assume file content available via ctx
        # Read file content
        content = ctx.file_read(update_image_path)
        # Use base64 encoding for binary-safe transport
        # Since Starlark lacks base64, we rely on curl to handle binary data
        # In practice, the module would use binary mode; here we simulate via ctx.run
        res = ctx.run(
            ["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type: application/octet-stream", "-u", username + ":" + password, "-T", update_image_path, url],
            mutates=True
        )
    else:
        res = ctx.run(
            ["curl", "-s", "-k", "-X", method, "-H", "Content-Type: application/json", "-d", payload_str, "-u", username + ":" + password, url],
            mutates=True
        )

    if res.skipped:
        return {"changed": True, "msg": "would execute " + command + " on " + category}

    if res.rc != 0:
        fail(command + " failed: " + res.stderr)

    response = res.stdout

    jobUri = ""
    operationStatusId = 0

    # Simple extraction for jobUri
    if '"JobUri":' in response:
        idx = response.find('"JobUri":')
        start = response.find('"', idx + 9) + 1
        end = response.find('"', start)
        if end != -1:
            jobUri = response[start:end]

    # Simple extraction for operationStatusId
    if '"OperationStatusId":' in response:
        idx = response.find('"OperationStatusId":')
        start = response.find(":", idx) + 1
        while start < len(response) and (response[start] == " " or response[start] == "\t"):
            start += 1
        end = start
        while end < len(response) and response[end].isdigit():
            end += 1
        if end > start:
            operationStatusId = int(response[start:end])

    msg = "Action was successful."
    changed = True

    if job_name != None and command == "DeleteJob":
        changed = True
    if command in ["FWUpload", "FWUpdate", "FWActivate"] and jobUri != "":
        msg = "Action initiated; job URI: " + jobUri

    return {
        "changed": changed,
        "msg": msg,
        "jobUri": jobUri,
        "operationStatusId": operationStatusId
    }
