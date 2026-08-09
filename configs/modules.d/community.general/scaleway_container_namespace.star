def main(ctx, params):
    name = params["name"]
    project_id = params["project_id"]
    region = params["region"]
    state = params.get("state", "present")
    description = params.get("description", "")
    environment_variables = params.get("environment_variables", {})
    secret_environment_variables = params.get("secret_environment_variables", {})
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    validate_certs = params.get("validate_certs", True)
    wait = params.get("wait", True)
    wait_sleep_time = params.get("wait_sleep_time", 3)
    wait_timeout = params.get("wait_timeout", 300)
    query_parameters = params.get("query_parameters", {})
    api_timeout = params.get("api_timeout", 30)

    if region not in ["fr-par", "nl-ams", "pl-waw"]:
        fail("region must be one of fr-par, nl-ams, pl-waw")

    api_path = "containers/v1beta1/regions/%s/namespaces" % region
    base_url = api_url.rstrip("/")

    def api_request(method, path, data=None, params_dict=None):
        url = base_url + "/" + path.lstrip("/")
        if params_dict:
            query_str = "&".join([str(k) + "=" + str(v) for k, v in params_dict.items()])
            url = url + "?" + query_str
        headers_list = ["-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json"]
        args = ["curl", "-s", "-X", method, "-L"] + headers_list + [url]
        if data:
            args = args + ["-d", str(data)]
        res = ctx.run(args, mutates=(method != "GET"))
        if res.rc != 0:
            fail("API request failed: " + res.stderr)
        return res

    def parse_namespace_list(data_str):
        namespaces = []
        inner = data_str.strip("[]")
        if not inner:
            return namespaces
        items = []
        depth = 0
        current = ""
        for c in inner:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    current += c
                    items.append(current.strip())
                    current = ""
                    continue
            if depth > 0 or (depth == 0 and c != ","):
                current += c
        if current.strip():
            items.append(current.strip())

        for item in items:
            item = item.strip()
            if not item:
                continue
            ns = {}
            item = item.strip("{}")
            pairs = item.split(",")
            for pair in pairs:
                if ":" not in pair:
                    continue
                idx = pair.find(":")
                key = pair[:idx].strip().strip('"')
                value = pair[idx+1:].strip().strip('"')
                value = value.replace('\\"', '"')
                ns[key] = value
            namespaces.append(ns)
        return namespaces

    def list_namespaces():
        res = api_request("GET", api_path)
        data = res.stdout.strip()
        if not data:
            return []
        return parse_namespace_list(data)

    def get_namespace_by_name(ns_list, ns_name):
        for ns in ns_list:
            if ns.get("name") == ns_name:
                return ns
        return None

    def wait_for_state(ns_id, expected_states, timeout=wait_timeout, sleep=wait_sleep_time):
        elapsed = 0
        while elapsed < timeout:
            res = api_request("GET", api_path + "/" + ns_id)
            if res.rc == 0:
                data = res.stdout.strip()
                status = ""
                idx = data.find('"status"')
                if idx != -1:
                    start = data.find('"', idx + 8) + 1
                    end = data.find('"', start)
                    if start > 0 and end > start:
                        status = data[start:end]
                if status in expected_states:
                    return True
            if ctx.check_mode:
                return True
            # Simulate sleep
            for _ in range(sleep):
                if elapsed >= timeout:
                    break
                elapsed += 1
                if elapsed >= timeout:
                    break
        fail("Timeout waiting for namespace state; elapsed: " + str(elapsed))

    namespaces = list_namespaces()
    existing = get_namespace_by_name(namespaces, name)

    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "Namespace %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "Namespace %s would be deleted" % name}
        ns_id = existing["id"]
        res = api_request("DELETE", api_path + "/" + ns_id)
        if res.rc != 0:
            fail("Failed to delete namespace: " + res.stderr)
        if wait:
            wait_for_state(ns_id, ["deleted", "absent"])
        return {"changed": True, "msg": "Namespace %s deleted" % name}

    # state == "present"
    if existing != None:
        ns_id = existing["id"]
        need_update = False
        updates = {}

        if description != existing.get("description", ""):
            need_update = True
            updates["description"] = description

        env_str = str(environment_variables)
        existing_env_str = str(existing.get("environment_variables", {}))
        if env_str != existing_env_str:
            need_update = True
            updates["environment_variables"] = environment_variables

        if not need_update:
            return {"changed": False, "msg": "Namespace %s already exists and up-to-date" % name}

        if ctx.check_mode:
            return {"changed": True, "msg": "Namespace %s attributes would be updated" % name}

        payload = {
            "description": description,
            "environment_variables": environment_variables
        }
        payload_items = []
        for k, v in payload.items():
            payload_items.append('"%s": "%s"' % (k, str(v).replace('"', '\\"')))
        payload_str = "{" + ", ".join(payload_items) + "}"

        res = api_request("PATCH", api_path + "/" + ns_id, data=payload_str)
        if res.rc != 0:
            fail("Failed to update namespace: " + res.stderr)
        if wait:
            wait_for_state(ns_id, ["ready", "pending"])
        res_get = api_request("GET", api_path + "/" + ns_id)
        summary = res_get.stdout.strip()
        return {"changed": True, "msg": "Namespace %s updated" % name, "data": {"container_namespace": summary}}

    # Create new namespace
    if ctx.check_mode:
        return {"changed": True, "msg": "Namespace %s would be created" % name}

    payload = {
        "project_id": project_id,
        "name": name,
        "description": description,
        "environment_variables": environment_variables
    }

    payload_items = []
    for k, v in payload.items():
        payload_items.append('"%s": "%s"' % (k, str(v).replace('"', '\\"')))
    payload_str = "{" + ", ".join(payload_items) + "}"

    res = api_request("POST", api_path, data=payload_str)
    if res.rc != 0:
        fail("Failed to create namespace: " + res.stderr)

    summary = res.stdout.strip()
    ns_id = ""
    idx = summary.find('"id"')
    if idx != -1:
        start = summary.find('"', idx + 4) + 1
        end = summary.find('"', start)
        if start > 0 and end > start:
            ns_id = summary[start:end]

    if wait and ns_id:
        wait_for_state(ns_id, ["ready", "pending"])
    return {"changed": True, "msg": "Namespace %s created" % name, "data": {"container_namespace": summary}}
