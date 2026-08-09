def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    validate_certs = params.get("validate_certs", True)
    mgmt_token = params["mgmt_token"]
    name = params.get("name")
    token = params.get("token")
    rules = params.get("rules", [])
    state = params.get("state", "present")
    token_type = params.get("token_type", "client")

    base_url = scheme + "://" + host + ":" + str(port) + "/v1/acl"

    # Helper to build ACL rules HCL string from list of dicts
    def encode_rules_as_hcl(rules_list):
        if not rules_list:
            return None
        hcl_parts = []
        for rule in rules_list:
            for scope in rule:
                if scope == "policy":
                    continue
                policy_val = rule.get("policy", "")
                if scope in ["keyring", "operator", "event", "node", "service", "session", "query"]:
                    hcl_parts.append(scope + " = \"" + policy_val + "\"")
                elif scope in ["key_prefix", "node_prefix", "service_prefix", "session_prefix", "query_prefix", "agent_prefix", "event_prefix"]:
                    pattern = rule.get(scope, "")
                    hcl_parts.append(scope + " \"" + pattern + "\" {")
                    hcl_parts.append("  policy = \"" + policy_val + "\"")
                    hcl_parts.append("}")
                elif scope in ["key", "node", "service", "event", "query", "session"]:
                    pattern = rule.get(scope, "")
                    hcl_parts.append(scope + " \"" + pattern + "\" {")
                    hcl_parts.append("  policy = \"" + policy_val + "\"")
                    hcl_parts.append("}")
                else:
                    fail("unsupported rule scope: " + scope)
        return "\n".join(hcl_parts)

    # Helper to normalize rules for comparison
    def normalize_rules(rules_list):
        normalized = {}
        for rule in rules_list:
            for scope in rule:
                if scope == "policy":
                    continue
                policy_val = rule.get("policy", "")
                if scope in ["keyring", "operator", "event", "node", "service", "session", "query"]:
                    normalized[scope] = policy_val
                elif scope in ["key", "node", "service", "event", "query", "session"]:
                    pattern = rule.get(scope, "")
                    if scope not in normalized:
                        normalized[scope] = {}
                    normalized[scope][pattern] = {"policy": policy_val}
                elif scope in ["key_prefix", "node_prefix", "service_prefix", "session_prefix", "query_prefix", "agent_prefix", "event_prefix"]:
                    pattern = rule.get(scope, "")
                    scope_base = scope.replace("_prefix", "")
                    if scope_base not in normalized:
                        normalized[scope_base] = {}
                    normalized[scope_base][pattern] = {"policy": policy_val}
                else:
                    fail("unsupported rule scope: " + scope)
        return normalized

    # Fetch existing ACLs
    list_url = base_url + "/list?token=" + mgmt_token
    res = ctx.run(["curl", "-sSf", "-XGET", list_url], mutates=False)
    if res.rc != 0:
        fail("failed to list ACLs: " + res.stderr)

    # Parse ACLs (basic JSON list parser for known format)
    def parse_json_list(json_str):
        acl_list = []
        # Strip outer brackets
        json_str = json_str.strip()
        if json_str == "":
            return acl_list
        # Find list content
        if not (json_str.startswith("[") and json_str.endswith("]")):
            return acl_list
        inner = json_str[1:-1].strip()
        if not inner:
            return acl_list

        # Split top-level objects
        items = []
        depth = 0
        current = ""
        for char in inner:
            if char == "{":
                depth += 1
                current += char
            elif char == "}":
                depth -= 1
                current += char
                if depth == 0:
                    items.append(current.strip())
                    current = ""
            elif depth > 0 or (char != "," or depth > 0):
                current += char
            elif depth == 0 and char == "," and current.strip() == "":
                continue
            elif depth == 0 and char == ",":
                if current.strip():
                    items.append(current.strip())
                current = ""
        if current.strip():
            items.append(current.strip())

        # Parse each item
        for item in items:
            if not item.startswith("{") or not item.endswith("}"):
                continue
            acl = {}
            item = item[1:-1].strip()
            # Extract ID
            if item.find("\"ID\"") != -1:
                idx = item.find("\"ID\"")
                rest = item[idx + 4:]
                if rest.startswith(":"):
                    rest = rest[1:].strip()
                    end = rest.find(",") if rest.find(",") != -1 else rest.find("}")
                    if end == -1:
                        end = len(rest)
                    val = rest[:end].strip().strip("\"")
                    acl["ID"] = val
            # Extract Name
            if item.find("\"Name\"") != -1:
                idx = item.find("\"Name\"")
                rest = item[idx + 6:]
                if rest.startswith(":"):
                    rest = rest[1:].strip()
                    end = rest.find(",") if rest.find(",") != -1 else rest.find("}")
                    if end == -1:
                        end = len(rest)
                    val = rest[:end].strip().strip("\"")
                    acl["Name"] = val
            # Extract Rules
            if item.find("\"Rules\"") != -1:
                idx = item.find("\"Rules\"")
                rest = item[idx + 7:]
                if rest.startswith(":"):
                    rest = rest[1:].strip()
                    end = rest.find(",") if rest.find(",") != -1 else rest.find("}")
                    if end == -1:
                        end = len(rest)
                    val = rest[:end].strip().strip("\"")
                    acl["Rules"] = val
            # Extract Type
            if item.find("\"Type\"") != -1:
                idx = item.find("\"Type\"")
                rest = item[idx + 6:]
                if rest.startswith(":"):
                    rest = rest[1:].strip()
                    end = rest.find(",") if rest.find(",") != -1 else rest.find("}")
                    if end == -1:
                        end = len(rest)
                    val = rest[:end].strip().strip("\"")
                    acl["Type"] = val
            if "ID" in acl:
                acl_list.append(acl)
        return acl_list

    acls = parse_json_list(res.stdout)

    # Index ACLs by name and token
    existing_by_name = {}
    existing_by_token = {}
    for acl in acls:
        if acl.get("Name"):
            existing_by_name[acl["Name"]] = acl
        token_val = acl.get("ID")
        if token_val:
            existing_by_token[token_val] = acl

    # Resolve target token if name is given
    if not token and name and name in existing_by_name:
        token = existing_by_name[name]["ID"]

    # Compute desired state
    desired_rules_hcl = encode_rules_as_hcl(rules)
    desired_rules_normalized = normalize_rules(rules)

    operation = None
    changed = False

    if state == "absent":
        if token and token in existing_by_token:
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove ACL"}
            destroy_url = base_url + "/destroy/" + token + "?token=" + mgmt_token
            res = ctx.run(["curl", "-sSf", "-XDELETE", destroy_url], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would remove ACL"}
            if res.rc != 0:
                fail("failed to destroy ACL: " + res.stderr)
            changed = True
            operation = "remove"
        else:
            changed = False
    else:  # present
        if token and token in existing_by_token:
            existing = existing_by_token[token]
            existing_rules_hcl = existing.get("Rules", "")
            # Compare HCL strings (case-insensitive, whitespace-insensitive)
            if desired_rules_hcl and existing_rules_hcl:
                desired_clean = desired_rules_hcl.strip().lower().replace(" ", "").replace("\n", "")
                existing_clean = existing_rules_hcl.strip().lower().replace(" ", "").replace("\n", "")
                if desired_clean != existing_clean:
                    changed = True
            elif desired_rules_hcl or existing_rules_hcl:
                changed = True
            if name and existing.get("Name") != name:
                changed = True
            if token_type != existing.get("Type"):
                changed = True

            if changed:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update ACL"}
                update_url = base_url + "/update?token=" + mgmt_token
                payload_name = name if name else existing.get("Name", "")
                payload_rules = desired_rules_hcl if desired_rules_hcl else ""
                json_str = "{\"ID\":\"" + token + "\","
                if payload_name:
                    json_str += "\"Name\":\"" + payload_name + "\","
                json_str += "\"Type\":\"" + token_type + "\","
                json_str += "\"Rules\":\"" + payload_rules.replace("\\", "\\\\").replace("\"", "\\\"") + "\"}"
                res = ctx.run([
                    "curl", "-sSf", "-XPUT",
                    "-H", "Content-Type: application/json",
                    "-d", json_str,
                    update_url
                ], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would update ACL"}
                if res.rc != 0:
                    fail("failed to update ACL: " + res.stderr)
                operation = "update"
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create ACL"}
            create_url = base_url + "/create?token=" + mgmt_token
            json_str = "{"
            if token:
                json_str += "\"ID\":\"" + token + "\","
            if name:
                json_str += "\"Name\":\"" + name + "\","
            json_str += "\"Type\":\"" + token_type + "\","
            json_str += "\"Rules\":\"" + (desired_rules_hcl if desired_rules_hcl else "").replace("\\", "\\\\").replace("\"", "\\\"") + "\"}"
            res = ctx.run([
                "curl", "-sSf", "-XPUT",
                "-H", "Content-Type: application/json",
                "-d", json_str,
                create_url
            ], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would create ACL"}
            if res.rc != 0:
                fail("failed to create ACL: " + res.stderr)
            # Parse token from response
            new_token = ""
            if res.stdout.find("\"ID\"") != -1:
                idx = res.stdout.find("\"ID\"")
                rest = res.stdout[idx + 4:]
                if rest.startswith(":"):
                    rest = rest[1:].strip()
                    end = rest.find(",") if rest.find(",") != -1 else rest.find("}")
                    if end == -1:
                        end = len(rest)
                    new_token = rest[:end].strip().strip("\"")
            if not new_token:
                fail("failed to parse new ACL token from response")
            token = new_token
            operation = "create"
        changed = operation != None

    return {"changed": changed, "msg": operation or "no change", "token": token, "operation": operation or ""}
