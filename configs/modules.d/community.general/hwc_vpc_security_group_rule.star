def main(ctx, params):
    state = params.get("state", "present")
    if state not in ("present", "absent"):
        fail("unsupported state: " + state)

    domain = params["domain"]
    project = params["project"]
    identity_endpoint = params["identity_endpoint"]
    user = params["user"]
    password = params["password"]
    region = params.get("region")
    security_group_id = params["security_group_id"]
    direction = params["direction"]
    if direction not in ("egress", "ingress"):
        fail("direction must be 'egress' or 'ingress'")

    ethertype = params.get("ethertype", "IPv4")
    if ethertype not in ("IPv4", "IPv6"):
        fail("ethertype must be 'IPv4' or 'IPv6'")

    protocol = params.get("protocol")
    if protocol != None and protocol not in ("icmp", "tcp", "udp"):
        fail("protocol must be 'icmp', 'tcp', 'udp', or omitted")

    port_range_min = params.get("port_range_min")
    port_range_max = params.get("port_range_max")
    if port_range_min != None and port_range_max != None:
        if int(port_range_max) < int(port_range_min):
            fail("port_range_max must be >= port_range_min")

    description = params.get("description")
    if description != None and len(description) > 255:
        fail("description must be no more than 255 characters")

    remote_group_id = params.get("remote_group_id")
    remote_ip_prefix = params.get("remote_ip_prefix")
    if remote_group_id != None and remote_ip_prefix != None:
        fail("remote_group_id and remote_ip_prefix are mutually exclusive")

    # Build auth token request
    auth_body = {
        "auth": {
            "identity": {
                "methods": ["password"],
                "password": {
                    "user": {
                        "name": user,
                        "password": password,
                        "domain": {"name": domain}
                    }
                }
            },
            "scope": {
                "project": {"name": project}
            }
        }
    }

    # Authenticate
    auth_resp = ctx.run([
        "curl", "-s", "-X", "POST", identity_endpoint + "/auth/tokens",
        "-H", "Content-Type: application/json",
        "-d", str(auth_body)
    ])
    if auth_resp.rc != 0:
        fail("authentication failed: " + auth_resp.stderr)

    # Extract token from response (simple extraction without json module)
    headers = auth_resp.stdout.split("\n\n")[0]
    token = ""
    for line in headers.split("\n"):
        if line.lower().startswith("x-subject-token:"):
            token = line.split(":", 1)[1].strip()
            break
    if not token:
        fail("could not extract auth token from response headers")

    # Build base URL for VPC API
    base_url = None
    # Try to find the VPC service endpoint from discovery (simplified)
    # For simplicity, assume the VPC URL pattern based on region if not provided
    region_val = region or "eu-west-0"
    base_url = "https://vpc." + region_val + ".myhuaweicloud.com/v1/" + project

    # Query existing rules
    list_url = base_url + "/security-group-rules?security_group_id=" + security_group_id
    list_resp = ctx.run([
        "curl", "-s", "-X", "GET", list_url,
        "-H", "Content-Type: application/json",
        "-H", "X-Auth-Token: " + token
    ])
    if list_resp.rc != 0:
        fail("failed to list security group rules: " + list_resp.stderr)

    # Parse rules manually (no json module)
    existing = []
    lines = list_resp.stdout.strip().split("\n")
    in_rules = False
    brace_depth = 0
    current_rule = {}
    for line in lines:
        stripped = line.strip()
        if stripped == '"security_group_rules": [' or stripped.startswith('"security_group_rules":['):
            in_rules = True
            continue
        if not in_rules:
            continue

        # Very basic extraction: detect objects by braces
        if stripped.startswith("{"):
            brace_depth = 1
            current_rule = {}
            continue
        if brace_depth > 0:
            # Handle nested braces for the rule object
            for c in stripped:
                if c == '{':
                    brace_depth += 1
                elif c == '}':
                    brace_depth -= 1
                    if brace_depth == 0:
                        existing.append(current_rule)
                        break
            # Extract key-value pairs as simple strings
            if brace_depth == 0 and current_rule.get("direction") != None:
                continue
            # Parse each line like "key": "value"
            if brace_depth == 0:
                # Try to parse key-value pairs from current line
                pass  # skip for simplicity

    # Simplified search: we'll reparse by line-by-line scanning
    # Re-run with a more robust manual parse (no json)
    current_rules = []
    # Strip outer brackets
    body = list_resp.stdout.strip()
    if body.startswith('{"security_group_rules":'):
        body = body[len('{"security_group_rules":'):]
    if body.endswith('}'):
        body = body[:-1]
    # Find each rule object
    depth = 0
    i = 0
    while i < len(body):
        if body[i] == '{':
            if depth == 0:
                start = i
            depth += 1
        elif body[i] == '}':
            depth -= 1
            if depth == 0:
                rule_str = body[start:i+1]
                # Parse key-value manually
                rule = {}
                # Very basic: split by "key": "value" pattern (no escapes considered)
                # Use simple string scanning
                key = ""
                val = ""
                in_key = False
                in_val = False
                j = 0
                while j < len(rule_str):
                    if rule_str[j] == '"':
                        if not in_key and not in_val:
                            in_key = True
                        elif in_key:
                            in_key = False
                            j += 2  # skip ": "
                            in_val = True
                        elif in_val:
                            in_val = False
                            # Parse val
                            val = ""
                            # Skip leading quotes and parse until next quote
                            k = j + 1
                            while k < len(rule_str) and rule_str[k] != '"':
                                val += rule_str[k]
                                k += 1
                            rule[key] = val
                            j = k
                        else:
                            in_val = False
                    elif in_key:
                        key += rule_str[j]
                    j += 1
                current_rules.append(rule)
        i += 1

    # Search for exact match by identity fields
    identity = {
        "direction": direction,
        "security_group_id": security_group_id,
        "ethertype": ethertype,
        "protocol": protocol,
        "port_range_min": str(port_range_min) if port_range_min != None else None,
        "port_range_max": str(port_range_max) if port_range_max != None else None,
        "remote_group_id": remote_group_id,
        "remote_ip_prefix": remote_ip_prefix,
        "description": description,
    }

    found_rule = None
    for rule in current_rules:
        match = True
        for k, v in identity.items():
            if v == None:
                if k in rule and rule[k] != "":
                    match = False
                    break
            else:
                if rule.get(k) != str(v):
                    match = False
                    break
        if match:
            found_rule = rule
            break

    # Determine desired state and act
    if state == "present":
        if found_rule != None:
            return {"changed": False, "msg": "security group rule already exists", "data": found_rule}
        if ctx.check_mode:
            return {"changed": True, "msg": "would create security group rule"}

        # Build create payload
        payload = {
            "security_group_rule": {
                "direction": direction,
                "security_group_id": security_group_id,
                "ethertype": ethertype,
            }
        }
        if description != None:
            payload["security_group_rule"]["description"] = description
        if protocol != None:
            payload["security_group_rule"]["protocol"] = protocol
        if port_range_min != None:
            payload["security_group_rule"]["port_range_min"] = port_range_min
        if port_range_max != None:
            payload["security_group_rule"]["port_range_max"] = port_range_max
        if remote_group_id != None:
            payload["security_group_rule"]["remote_group_id"] = remote_group_id
        if remote_ip_prefix != None:
            payload["security_group_rule"]["remote_ip_prefix"] = remote_ip_prefix

        # Create via API
        create_resp = ctx.run([
            "curl", "-s", "-X", "POST", base_url + "/security-group-rules",
            "-H", "Content-Type: application/json",
            "-H", "X-Auth-Token: " + token,
            "-d", str(payload)
        ])
        if create_resp.rc != 0:
            fail("failed to create security group rule: " + create_resp.stderr)

        # Parse created ID
        created_id = ""
        # Simple extraction: look for "id": "..." in output
        lines = create_resp.stdout.split("\n")
        for line in lines:
            if '"id":' in line:
                # Extract ID value
                parts = line.split('"id":')
                if len(parts) > 1:
                    id_part = parts[1].strip()
                    if id_part.startswith('"'):
                        id_part = id_part[1:]
                    if id_part.endswith('"'):
                        id_part = id_part[:-1]
                    created_id = id_part
                    break

        if not created_id:
            fail("could not extract rule ID from creation response")

        result = {
            "direction": direction,
            "security_group_id": security_group_id,
            "id": created_id,
        }
        if ethertype != None:
            result["ethertype"] = ethertype
        if protocol != None:
            result["protocol"] = protocol
        if port_range_min != None:
            result["port_range_min"] = port_range_min
        if port_range_max != None:
            result["port_range_max"] = port_range_max
        if remote_group_id != None:
            result["remote_group_id"] = remote_group_id
        if remote_ip_prefix != None:
            result["remote_ip_prefix"] = remote_ip_prefix
        if description != None:
            result["description"] = description

        return {"changed": True, "msg": "security group rule created", "data": result}

    else:  # absent
        if found_rule == None:
            return {"changed": False, "msg": "security group rule does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete security group rule"}

        rule_id = found_rule.get("id")
        if not rule_id:
            fail("found rule has no id")

        delete_url = base_url + "/security-group-rules/" + rule_id
        delete_resp = ctx.run([
            "curl", "-s", "-X", "DELETE", delete_url,
            "-H", "X-Auth-Token: " + token
        ])
        if delete_resp.rc != 0:
            fail("failed to delete security group rule: " + delete_resp.stderr)

        return {"changed": True, "msg": "security group rule deleted"}
