def main(ctx, params):
    name = params["name"]
    service = params["service"]
    endpoint = params["endpoint"]
    application_key = params["application_key"]
    application_secret = params["application_secret"]
    consumer_key = params["consumer_key"]
    timeout = params.get("timeout", 120)
    wait_completion = params.get("wait_completion", True)
    wait_task_completion = params.get("wait_task_completion", 0)

    api_base = "https://api.%s.ovh.net/1.0" % endpoint

    def ovh_request(method, path, data=None):
        headers = [
            "-H", "Accept: application/json",
            "-H", "X-OVH-Application: " + application_key,
            "-H", "X-OVH-Consumer: " + consumer_key,
            "-H", "X-OVH-Signature: " + application_secret
        ]
        if ctx.check_mode and method in ["POST", "PUT", "DELETE"]:
            return {"skipped": True, "rc": 0, "stdout": '{"taskId":0}', "stderr": ""}
        argv = ["curl", "-s", "-X", method] + headers
        if data:
            argv.extend(["-d", data])
        argv.append(api_base + path)
        res = ctx.run(argv, mutates=False if method == "GET" else True)
        return res

    # Check IP exists
    res = ovh_request("GET", "/ip?ip=" + name + "&type=failover")
    if res.skipped:
        return {"changed": False, "msg": "check_mode: would check IP existence"}
    if res.rc != 0:
        fail("Failed to fetch IPs from OVH: " + res.stderr)

    # Parse JSON-like array output manually
    raw_ips = res.stdout.strip()
    ips_list = []
    if raw_ips != "[]" and raw_ips != "":
        inner = raw_ips.strip("[]")
        parts = inner.split(",") if "," in inner else [inner]
        for part in parts:
            part = part.strip().strip('"')
            if part != "":
                ips_list.append(part)
    ip_exists = name in ips_list or (name + "/32") in ips_list
    if not ip_exists:
        fail("IP " + name + " does not exist in your OVH account")

    # Wait for no pending genericMoveFloatingIp tasks
    def wait_no_task(timeout_secs):
        remaining = timeout_secs
        while remaining > 0:
            res = ovh_request("GET", "/ip/" + name + "/task?function=genericMoveFloatingIp&status=todo")
            if res.skipped:
                return True
            if res.rc != 0:
                return False
            tasks = res.stdout.strip()
            if tasks == "[]" or tasks == "":
                return True
            remaining = remaining - 1
        return False

    if not wait_no_task(timeout):
        fail("Timeout while waiting for pending tasks to clear")

    # Get IP properties
    res = ovh_request("GET", "/ip/" + name)
    if res.skipped:
        current_service = None
    elif res.rc != 0:
        fail("Failed to get IP properties: " + res.stderr)
    else:
        current_service = ""
        start_idx = res.stdout.find('"serviceName":"')
        if start_idx != -1:
            start_idx = start_idx + len('"serviceName":"')
            end_idx = res.stdout.find('"', start_idx)
            if end_idx != -1:
                current_service = res.stdout[start_idx:end_idx]

    # Decide if change needed
    if current_service != service:
        if ctx.check_mode:
            return {"changed": True, "msg": "would route " + name + " to " + service}

        # Perform move
        data = '{"to": "' + service + '"}'
        res = ovh_request("POST", "/ip/" + name + "/move", data)
        if res.skipped:
            return {"changed": False, "msg": "unexpected skipped response"}

        if res.rc != 0:
            fail("Failed to move IP: " + res.stderr)

        # Extract taskId manually
        task_id = 0
        start_idx = res.stdout.find('"taskId":')
        if start_idx != -1:
            start_idx = start_idx + len('"taskId":')
            substr = res.stdout[start_idx:start_idx + 10]
            number_str = ""
            for c in substr:
                if c.isdigit():
                    number_str = number_str + c
                else:
                    break
            if number_str != "":
                task_id = int(number_str)

        # Wait for completion if requested
        waited = False
        if wait_completion or wait_task_completion != 0:
            target_task = wait_task_completion if wait_task_completion != 0 else task_id
            remaining = timeout
            while remaining > 0:
                res = ovh_request("GET", "/ip/" + name + "/task/" + str(target_task))
                if res.skipped:
                    waited = True
                    break
                if res.rc != 0:
                    fail("Failed to fetch task status: " + res.stderr)
                status = ""
                start_idx = res.stdout.find('"status":"')
                if start_idx != -1:
                    start_idx = start_idx + len('"status":"')
                    end_idx = res.stdout.find('"', start_idx)
                    if end_idx != -1:
                        status = res.stdout[start_idx:end_idx]
                if status == "done":
                    waited = True
                    break
                remaining = remaining - 5
                waited = True
            if not waited and remaining <= 0:
                fail("Timeout while waiting for task " + str(target_task) + " completion")

        return {
            "changed": True,
            "msg": "routed " + name + " to " + service,
            "data": {
                "taskId": task_id,
                "waited": waited
            }
        }

    return {"changed": False, "msg": name + " already routed to " + service}
