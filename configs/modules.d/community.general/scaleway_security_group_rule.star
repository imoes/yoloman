def main(ctx, params):
    # Required parameters
    action = params["action"]
    api_token = params["api_token"]
    direction = params["direction"]
    port = params["port"]
    protocol = params["protocol"]
    region = params["region"]
    security_group = params["security_group"]
    state = params.get("state", "present")
    api_url = params.get("api_url", "https://api.scaleway.com")
    ip_range = params.get("ip_range", "0.0.0.0/0")

    # Region endpoints mapping
    region_endpoints = {
        "ams1": "https://api.scaleway.com",
        "EMEA-NL-EVS": "https://api.scaleway.com",
        "par1": "https://api.scaleway.com",
        "EMEA-FR-PAR1": "https://api.scaleway.com",
        "par2": "https://api.scaleway.com",
        "EMEA-FR-PAR2": "https://api.scaleway.com",
        "waw1": "https://api.scaleway.com",
        "EMEA-PL-WAW1": "https://api.scaleway.com"
    }
    base_url = region_endpoints.get(region, "https://api.scaleway.com")

    # Build rule payload
    rule = {
        "protocol": protocol,
        "dest_port_from": port,
        "ip_range": ip_range,
        "direction": direction,
        "action": action
    }

    # Helper to get rules list via curl
    def get_rules():
        headers_list = [
            "-H", "Authorization: Bearer " + api_token,
            "-H", "Content-Type: application/json"
        ]
        argv = ["curl", "-s", "-X", "GET"] + headers_list + [base_url + "/security_groups/%s/rules" % security_group]
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            fail("Error getting security group rules: " + res.stderr)
        stdout = res.stdout.strip()
        if stdout == "":
            return []
        # Parse JSON manually (simple extraction)
        # Expecting {"rules":[...]} format
        if not stdout.startswith("{\"rules\":"):
            fail("Unexpected response format: " + stdout)
        # Find array content
        start_idx = stdout.find("[")
        end_idx = stdout.rfind("]")
        if start_idx == -1 or end_idx == -1:
            fail("Could not parse rules array from response")
        arr_str = stdout[start_idx:end_idx+1]
        return parse_rules_array(arr_str)

    # Helper to parse rules array (simple JSON array parser for known structure)
    def parse_rules_array(arr_str):
        # Remove outer brackets
        if arr_str.startswith("[") and arr_str.endswith("]"):
            arr_str = arr_str[1:-1]
        if arr_str.strip() == "":
            return []
        # Split objects by "id": pattern
        parts = []
        current = ""
        brace_count = 0
        for c in arr_str:
            if c == "{":
                brace_count = brace_count + 1
            elif c == "}":
                brace_count = brace_count - 1
            if c == "," and brace_count == 0:
                parts.append(current.strip())
                current = ""
                continue
            current = current + c
        parts.append(current.strip())
        rules = []
        for p in parts:
            if p == "":
                continue
            rule_obj = parse_rule_object(p)
            if rule_obj != None:
                rules.append(rule_obj)
        return rules

    def parse_rule_object(obj_str):
        # Very basic parser for our known rule fields
        obj = {}
        # Remove braces
        obj_str = obj_str.strip()
        if obj_str.startswith("{"):
            obj_str = obj_str[1:]
        if obj_str.endswith("}"):
            obj_str = obj_str[:-1]
        # Split by comma and parse key-value
        parts = obj_str.split(",")
        for part in parts:
            part = part.strip()
            if part == "":
                continue
            idx = part.find(":")
            if idx == -1:
                continue
            key = part[:idx].strip().strip("\"")
            val_part = part[idx+1:].strip()
            # Extract value
            if val_part.startswith("\""):
                # String value
                end_quote = val_part.find("\"", 1)
                if end_quote != -1:
                    value = val_part[1:end_quote]
                else:
                    value = ""
            elif val_part == "null":
                value = None
            elif val_part == "true":
                value = True
            elif val_part == "false":
                value = False
            elif val_part.isdigit() or (val_part.startswith("-") and val_part[1:].isdigit()):
                value = int(val_part)
            else:
                value = val_part
            obj[key] = value
        return obj

    # Helper to find existing rule
    def find_existing_rule(rules):
        for r in rules:
            r_dir = r.get("direction")
            r_proto = r.get("protocol")
            r_ip = r.get("ip_range")
            r_action = r.get("action")
            r_port = r.get("dest_port_from")
            # Handle null port case
            if port == None and r_port != None:
                continue
            if port != None and r_port == None:
                continue
            if port != None and r_port != None and int(port) != int(r_port):
                continue
            if r_dir == direction and r_proto == protocol and r_ip == ip_range and r_action == action:
                return r
        return None

    # Helper to delete rule
    def delete_rule(rule_id):
        headers_list = [
            "-H", "Authorization: Bearer " + api_token,
            "-H", "Content-Type: application/json"
        ]
        argv = ["curl", "-s", "-X", "DELETE"] + headers_list + [base_url + "/security_groups/%s/rules/%s" % (security_group, rule_id)]
        res = ctx.run(argv, mutates=True)
        if res.rc != 0:
            fail("Error deleting security group rule: " + res.stderr)

    if state == "present":
        # Check existence
        rules = get_rules()
        existing = find_existing_rule(rules)

        if existing != None:
            return {"changed": False, "data": {"scaleway_security_group_rule": existing}}

        if ctx.check_mode:
            return {"changed": True, "msg": "would create security group rule"}

        # Create rule
        headers_list = [
            "-H", "Authorization: Bearer " + api_token,
            "-H", "Content-Type: application/json"
        ]
        # Build JSON payload manually
        port_str = "null" if port == None else str(port)
        action_str = "\"" + action + "\""
        direction_str = "\"" + direction + "\""
        protocol_str = "\"" + protocol + "\""
        ip_range_str = "\"" + ip_range + "\""
        payload = "{\"rule\":{\"action\":" + action_str + ",\"direction\":" + direction_str + ",\"protocol\":" + protocol_str + ",\"ip_range\":" + ip_range_str + ",\"dest_port_from\":" + port_str + ",\"dest_port_to\":null}}"
        argv = ["curl", "-s", "-X", "POST"] + headers_list + ["--data", payload, base_url + "/security_groups/%s/rules" % security_group]
        res = ctx.run(argv, mutates=True)
        if res.rc != 0:
            fail("Error creating security group rule: " + res.stderr)
        stdout = res.stdout.strip()
        if stdout == "":
            fail("Empty response when creating security group rule")
        # Parse result to extract rule
        start_idx = stdout.find("\"rule\":{")
        if start_idx == -1:
            fail("Could not find rule in response: " + stdout)
        rule_str = stdout[start_idx+8:]
        # Find closing brace
        brace_count = 0
        end_idx = -1
        for i in range(len(rule_str)):
            c = rule_str[i]
            if c == "{":
                brace_count = brace_count + 1
            elif c == "}":
                brace_count = brace_count - 1
                if brace_count == 0:
                    end_idx = i
                    break
        if end_idx == -1:
            fail("Could not parse rule object: " + rule_str)
        rule_json = "{" + rule_str[:end_idx+1] + "}"
        rule_obj = parse_rule_object(rule_json)
        return {"changed": True, "msg": "security group rule created", "data": {"scaleway_security_group_rule": rule_obj}}

    elif state == "absent":
        # Check existence
        rules = get_rules()
        existing = find_existing_rule(rules)

        if existing == None:
            return {"changed": False, "msg": "rule already absent"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete security group rule"}

        # Delete rule
        rule_id = existing.get("id")
        if rule_id == None:
            fail("Rule missing id for deletion")
        delete_rule(rule_id)
        return {"changed": True, "msg": "security group rule deleted"}

    fail("unsupported state: " + state)
