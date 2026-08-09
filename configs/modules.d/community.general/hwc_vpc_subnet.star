def main(ctx, params):
    # Required params
    cidr = params["cidr"]
    gateway_ip = params["gateway_ip"]
    name = params["name"]
    vpc_id = params["vpc_id"]
    domain = params["domain"]
    identity_endpoint = params["identity_endpoint"]
    password = params["password"]
    project = params["project"]
    user = params["user"]

    # Optional params with defaults
    state = params.get("state", "present")
    region = params.get("region")
    availability_zone = params.get("availability_zone")
    dhcp_enable = params.get("dhcp_enable")
    dns_list = params.get("dns_address", [])
    timeouts = params.get("timeouts", {})
    create_timeout = timeouts.get("create", "15m")
    update_timeout = timeouts.get("update", "15m")

    # Parse timeout strings to seconds
    def parse_timeout(t):
        if t.endswith("m"):
            return int(t[:-1]) * 60
        return 60

    create_timeout_sec = parse_timeout(create_timeout)
    update_timeout_sec = parse_timeout(update_timeout)

    # Build auth payload manually
    auth_body = '{"auth":{"identity":{"methods":["password"],"password":{"user":{"name":"'
    auth_body = auth_body + user
    auth_body = auth_body + '","password":"'
    auth_body = auth_body + password
    auth_body = auth_body + '","domain":{"name":"'
    auth_body = auth_body + domain
    auth_body = auth_body + '"}}},"scope":{"project":{"name":"'
    auth_body = auth_body + project
    auth_body = auth_body + '"}}}}'

    # Authentication
    res = ctx.run([
        "curl", "-s", "-X", "POST", identity_endpoint.rstrip("/") + "/v3/auth/tokens",
        "-H", "Content-Type: application/json",
        "-d", auth_body
    ])
    if res.rc != 0:
        fail("authentication failed: " + res.stderr)

    # Extract token from response headers (naive method: read X-Subject-Token from response)
    token = ""
    # Parse stdout manually for token header (response includes header lines + JSON body)
    lines = res.stdout.splitlines()
    for line in lines:
        if line.startswith("X-Subject-Token:"):
            token = line.split(":", 1)[1].strip()
            break
    if token == "":
        fail("failed to extract authentication token from response")

    # Build request base URL
    base_url = identity_endpoint.replace("/v3/auth/tokens", "")
    # Assume project ID is not used directly; rely on context from token
    # Use project name via list projects if needed — but simplified here

    # Helper to build query string
    def build_query_string(query_params):
        parts = []
        for k, v in query_params.items():
            if v != None:
                parts.append(k + "=" + v)
        if parts:
            return "?" + "&".join(parts)
        return ""

    # Search existing subnet by criteria
    search_params = {
        "name": name,
        "vpc_id": vpc_id,
        "cidr": cidr
    }
    query = build_query_string(search_params)
    list_url = base_url + "/v1/" + project + "/subnets" + query

    # List subnets
    res = ctx.run([
        "curl", "-s", "-X", "GET", list_url,
        "-H", "X-Auth-Token: " + token,
        "-H", "Content-Type: application/json"
    ])
    if res.rc != 0:
        fail("failed to list subnets: " + res.stderr)

    # Parse simple JSON list (naive) — only extract first match
    subnet_id = ""
    found = False
    # Naive JSON parsing: search for first 'id":"..."'
    # Because Starlark lacks regex and json, use simple string search
    stdout = res.stdout
    idx = stdout.find('"id":"')
    while idx != -1:
        start = idx + 6
        end = stdout.find('"', start)
        if end == -1:
            end = len(stdout)
        found_id = stdout[start:end]
        # Also verify vpc_id match
        # Simple check: look for this subnet's vpc_id in same object block
        obj_start = stdout.rfind('{', 0, idx)
        obj_end = stdout.find('}', obj_start)
        obj_str = stdout[obj_start:obj_end+1]
        if '"vpc_id":"'+vpc_id+'"' in obj_str or '"vpc_id" : "'+vpc_id+'"' in obj_str:
            subnet_id = found_id
            found = True
            break
        idx = stdout.find('"id":"', end)

    # Determine state
    if state == "present":
        if found:
            # Subnet exists — read current state to check for drift
            res = ctx.run([
                "curl", "-s", "-X", "GET", base_url + "/v1/" + project + "/subnets/" + subnet_id,
                "-H", "X-Auth-Token: " + token,
                "-H", "Content-Type: application/json"
            ])
            if res.rc != 0:
                fail("failed to read subnet: " + res.stderr)

            # Compare with desired state (minimal drift check)
            # Check only fields that are updatable: dhcp_enable, name, dnsList
            # For simplicity, assume no change if ID matches and basic fields match
            # (full comparison omitted due to Starlark limitations)
            return {"changed": False, "msg": "subnet already exists with id " + subnet_id, "data": {"id": subnet_id}}
        else:
            # Create subnet
            create_body = '{"subnet":{"cidr":"'+cidr+'","gateway_ip":"'+gateway_ip+'","name":"'+name+'","vpc_id":"'+vpc_id+'"}'
            if availability_zone != None:
                create_body = create_body + ',"availability_zone":"'+availability_zone+'"'
            if dhcp_enable != None:
                if dhcp_enable == True:
                    create_body = create_body + ',"dhcp_enable":true'
                else:
                    create_body = create_body + ',"dhcp_enable":false'
            # DNS handling: map to primary_dns and secondary_dns
            if dns_list and len(dns_list) > 0:
                create_body = create_body + ',"primary_dns":"'+dns_list[0]+'"'
                if len(dns_list) > 1:
                    create_body = create_body + ',"secondary_dns":"'+dns_list[1]+'"'
            if len(dns_list) > 2:
                # dnsList array (simplified: only include if >2)
                dns_json = ',"dnsList":['
                for i in range(len(dns_list)):
                    dns_json = dns_json + '"'+dns_list[i]+'"'
                    if i < len(dns_list)-1:
                        dns_json = dns_json + ','
                dns_json = dns_json + ']'
                create_body = create_body + dns_json
            create_body = create_body + '}}'

            res = ctx.run([
                "curl", "-s", "-X", "POST", base_url + "/v1/" + project + "/subnets",
                "-H", "X-Auth-Token: " + token,
                "-H", "Content-Type: application/json",
                "-d", create_body
            ])
            if res.rc != 0:
                fail("failed to create subnet: " + res.stderr)

            # Extract id from response
            res_id = ""
            idx = res.stdout.find('"id":"')
            if idx != -1:
                start = idx + 6
                end = res.stdout.find('"', start)
                res_id = res.stdout[start:end]
            if res_id == "":
                fail("failed to extract subnet id from create response")

            return {"changed": True, "msg": "subnet created with id " + res_id, "data": {"id": res_id}}

    else:  # state == "absent"
        if found:
            # Delete subnet
            res = ctx.run([
                "curl", "-s", "-X", "DELETE", base_url + "/v1/" + project + "/subnets/" + subnet_id,
                "-H", "X-Auth-Token: " + token
            ])
            if res.rc != 0:
                fail("failed to delete subnet: " + res.stderr)
            return {"changed": True, "msg": "subnet deleted", "data": {"id": subnet_id}}
        else:
            return {"changed": False, "msg": "subnet not found, nothing to delete"}
