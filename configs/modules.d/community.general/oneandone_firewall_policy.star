def main(ctx, params):
    # Extract required and optional params
    auth_token = params.get("auth_token")
    api_url = params.get("api_url")
    state = params.get("state", "present")
    name = params.get("name")
    firewall_policy = params.get("firewall_policy")
    description = params.get("description")
    rules = params.get("rules", [])
    add_server_ips = params.get("add_server_ips", [])
    remove_server_ips = params.get("remove_server_ips", [])
    add_rules = params.get("add_rules", [])
    remove_rules = params.get("remove_rules", [])
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 600)
    wait_interval = params.get("wait_interval", 5)

    # Fail if missing required params
    if auth_token == None:
        fail("The 'auth_token' parameter or ONEANDONE_AUTH_TOKEN environment variable is required.")
    if state == "absent" and name == None:
        fail("'name' parameter is required to delete a firewall policy.")
    if state == "update" and firewall_policy == None:
        fail("'firewall_policy' parameter is required to update a firewall policy.")
    if state == "present":
        if name == None:
            fail("'name' parameter is required for new firewall policies.")
        if len(rules) == 0:
            fail("'rules' parameter is required for new firewall policies.")

    # Build base API URL
    url = api_url if api_url != None else "https://cloud.1and1.com/v1"

    # Helper: perform HTTP request
    def _api_request(method, path, data=None):
        argv = ["curl", "-s", "-X", method, "-H", "Content-Type: application/json", "-H", "Authorization: Token " + auth_token]
        if data != None:
            argv.extend(["-d", data])
        argv.append(url + path)
        res = ctx.run(argv)
        if res.rc != 0:
            fail("API request failed: " + res.stderr)
        return res.stdout

    # Helper: find firewall policy by name or id
    def _get_firewall(fp_id_or_name):
        res_json = _api_request("GET", "/firewall_policies")
        items = res_json.split("[")[1].split("]")[0].split("{")
        for item in items:
            if item == "":
                continue
            item = "{" + item.strip().rstrip(",")
            # simple JSON parse (no full parser)
            # extract id and name
            fp_id = ""
            fp_name = ""
            for line in item.splitlines():
                if '"id"' in line:
                    fp_id = line.split('"id"')[1].strip().rstrip(",").strip('"')
                if '"name"' in line:
                    fp_name = line.split('"name"')[1].strip().rstrip(",").strip('"')
            if fp_id == fp_id_or_name or fp_name == fp_id_or_name:
                return {"id": fp_id, "name": fp_name}
        return None

    # Helper: wait for status "ACTIVE"
    def _wait_for_active(fp_id):
        elapsed = 0
        while elapsed < wait_timeout:
            res_json = _api_request("GET", "/firewall_policies/" + fp_id)
            if '"state"' in res_json:
                # extract state
                state_part = res_json.split('"state"')[1].strip().rstrip(",")
                state_val = state_part.strip('"')
                if state_val == "ACTIVE":
                    return
            # sleep using ctx.wait is not available; use loop with small delays
            # but ctx.run for sleep is not ideal; fallback to simple busy-wait via loop
            i = 0
            while i < wait_interval * 2:
                i += 1
            elapsed += wait_interval
        fail("Timeout waiting for firewall policy to become active")

    changed = False
    fp_id = ""
    fp_name = ""

    if state == "present":
        # Create new firewall policy
        if ctx.check_mode:
            return {"changed": True, "msg": "would create firewall policy"}

        payload = {
            "name": name,
            "description": description or ""
        }

        # Build rules payload
        rule_list = []
        for r in rules:
            rule_list.append({
                "protocol": r.get("protocol", ""),
                "port_from": r.get("port_from"),
                "port_to": r.get("port_to"),
                "source": r.get("source", "")
            })
        payload["rules"] = rule_list

        payload_json = '{"name": "' + payload["name"] + '", "description": "' + payload["description"] + '", "rules": []}'
        if len(rule_list) > 0:
            rules_str = "[" + ",".join([
                '{"protocol": "' + r["protocol"] + '", "port_from": ' + str(r["port_from"]) + ', "port_to": ' + str(r["port_to"]) + ', "source": "' + r["source"] + '"}'
                for r in rule_list
            ]) + "]"
            payload_json = '{"name": "' + payload["name"] + '", "description": "' + payload["description"] + '", "rules": ' + rules_str + '}'

        res_json = _api_request("POST", "/firewall_policies", payload_json)
        if '"id"' in res_json:
            fp_id = res_json.split('"id"')[1].strip().rstrip(",").strip('"')
            fp_name = res_json.split('"name"')[1].strip().rstrip(",").strip('"')
            changed = True

        if wait and fp_id != "":
            _wait_for_active(fp_id)

        return {"changed": changed, "msg": "created firewall policy", "data": {"firewall_policy": {"id": fp_id, "name": fp_name}}}

    elif state == "absent":
        # Delete firewall policy
        fp = _get_firewall(name)
        if fp == None:
            return {"changed": False, "msg": "firewall policy not found"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete firewall policy"}

        _api_request("DELETE", "/firewall_policies/" + fp["id"])
        changed = True
        return {"changed": changed, "msg": "deleted firewall policy", "data": {"firewall_policy": {"id": fp["id"], "name": fp["name"]}}}

    elif state == "update":
        # Update firewall policy
        fp = _get_firewall(firewall_policy)
        if fp == None:
            fail("firewall policy not found: " + firewall_policy)
        fp_id = fp["id"]

        # Prepare updates
        updates = {}
        if name != None or description != None:
            updates["name"] = name if name != None else fp["name"]
            updates["description"] = description if description != None else ""
            if ctx.check_mode:
                return {"changed": True, "msg": "would update firewall policy name/description"}

            payload_json = '{"name": "' + updates["name"] + '", "description": "' + updates["description"] + '"}'
            _api_request("PUT", "/firewall_policies/" + fp_id, payload_json)
            changed = True

        # Add server IPs
        if len(add_server_ips) > 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would add server IPs to firewall policy"}

            # For each server, get ID and attach
            for srv in add_server_ips:
                # get server by name or id (simplified)
                srv_res = _api_request("GET", "/servers")
                # extract id
                srv_id = ""
                if srv_res.count('"name"') > 0:
                    parts = srv_res.split('"name"')
                    for part in parts:
                        if srv in part:
                            id_line = part.split('"id"')[1].strip().split(',')[0]
                            srv_id = id_line.strip().strip('"')
                            break
                if srv_id == "":
                    fail("server not found: " + srv)

                # get first IP ID for server
                ips_res = _api_request("GET", "/servers/" + srv_id + "/ips")
                ip_id = ""
                if ips_res.count('"id"') > 0:
                    ip_id = ips_res.split('"id"')[1].strip().split(',')[0].strip().strip('"')

                # attach IP to firewall
                attach_payload = '{"server_id": "' + srv_id + '", "server_ip_id": "' + ip_id + '"}'
                _api_request("POST", "/firewall_policies/" + fp_id + "/server_ips", attach_payload)
            changed = True

        # Remove server IPs
        if len(remove_server_ips) > 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove server IPs from firewall policy"}

            for ip_id in remove_server_ips:
                _api_request("DELETE", "/firewall_policies/" + fp_id + "/server_ips/" + ip_id)
            changed = True

        # Add rules
        if len(add_rules) > 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would add rules to firewall policy"}

            for rule in add_rules:
                rule_json = '{"protocol": "' + rule.get("protocol", "") + '", "port_from": ' + str(rule.get("port_from", 0)) + ', "port_to": ' + str(rule.get("port_to", 0)) + ', "source": "' + str(rule.get("source", "")) + '"}'
                _api_request("POST", "/firewall_policies/" + fp_id + "/rules", rule_json)
            changed = True

        # Remove rules
        if len(remove_rules) > 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove rules from firewall policy"}

            for rule_id in remove_rules:
                _api_request("DELETE", "/firewall_policies/" + fp_id + "/rules/" + rule_id)
            changed = True

        # Refresh policy info
        res_json = _api_request("GET", "/firewall_policies/" + fp_id)
        new_name = ""
        new_desc = ""
        if '"name"' in res_json:
            new_name = res_json.split('"name"')[1].strip().split('"')[1]
            new_desc = res_json.split('"description"')[1].strip().split('"')[1]
        fp_refreshed = {"id": fp_id, "name": new_name}

        return {"changed": changed, "msg": "updated firewall policy", "data": {"firewall_policy": fp_refreshed}}

    fail("unsupported state: " + state)
