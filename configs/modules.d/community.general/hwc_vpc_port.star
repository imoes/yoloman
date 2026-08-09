def main(ctx, params):
    # Required fields validation
    if not params.get("subnet_id"):
        fail("subnet_id is required")
    if not params.get("domain"):
        fail("domain is required")
    if not params.get("project"):
        fail("project is required")
    if not params.get("user"):
        fail("user is required")
    if not params.get("password"):
        fail("password is required")
    if not params.get("identity_endpoint"):
        fail("identity_endpoint is required")

    state = params.get("state", "present")
    region = params.get("region", "")
    identity_endpoint = params["identity_endpoint"]
    domain = params["domain"]
    project = params["project"]
    user = params["user"]
    password = params["password"]
    subnet_id = params["subnet_id"]
    port_id = params.get("id")
    timeouts_create = params.get("timeouts", {}).get("create", "15m")
    # Parse timeout (strip 'm' suffix)
    if timeouts_create.endswith("m"):
        timeout_min = int(timeouts_create[:-1])
    else:
        fail("invalid timeouts.create format: " + timeouts_create)
    timeout_ms = timeout_min * 60 * 1000

    # Helper to build auth URL
    auth_url = identity_endpoint.rstrip("/") + "/v3/auth/tokens"

    # Helper: authenticate and get token
    def get_token():
        payload = {
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
        res = ctx.run([
            "curl", "-s", "-X", "POST", auth_url,
            "-H", "Content-Type: application/json",
            "-d", str(payload)
        ], mutates=False)
        if res.rc != 0:
            fail("authentication failed: " + res.stderr)
        # Extract X-Subject-Token from response headers (curl -D - style)
        headers = res.stdout
        token = None
        for line in headers.splitlines():
            if line.startswith("X-Subject-Token:"):
                token = line.split(":", 1)[1].strip()
                break
        if not token:
            fail("authentication: could not extract token")
        return token

    token = get_token()

    # Helper: make authenticated VPC API request
    def vpc_request(method, path, json_body=None, token=token, region=region):
        url = "https://vpc." + region + ".myhwclouds.com/v1/" + project + path
        args = ["curl", "-s", "-X", method, url]
        args.extend(["-H", "Content-Type: application/json"])
        args.extend(["-H", "X-Auth-Token: " + token])
        if json_body:
            args.extend(["-d", str(json_body)])
        res = ctx.run(args, mutates=method in ["POST", "PUT", "DELETE"])
        if res.rc != 0:
            fail("API " + method + " " + path + " failed: " + res.stderr)
        return res

    # Search for existing port
    def search_port():
        query = "?network_id=" + subnet_id
        if params.get("name"):
            query += "&name=" + params["name"]
        if params.get("admin_state_up") != None:
            query += "&admin_state_up=" + ("true" if params["admin_state_up"] else "false")
        res = vpc_request("GET", "/ports" + query)
        ports = res.stdout
        # Simple parsing for JSON array of ports
        if '"ports":' in ports:
            start = ports.index('"ports":') + len('"ports":')
            end = ports.rfind("]", start)
            if end > start:
                inner = ports[start:end+1].strip()
                # split by "id":
                parts = inner.split('"id":')
                port_list = []
                for part in parts[1:]:
                    pid = part.split('"')[0].strip()
                    port_list.append({"id": pid})
                return port_list
        return []

    # Read port details
    def read_port(pid):
        res = vpc_request("GET", "/ports/" + pid)
        body = res.stdout
        # Parse JSON fields manually (naive)
        def get_json_str(key):
            pattern = '"' + key + '":'
            if pattern in body:
                idx = body.index(pattern) + len(pattern)
                rest = body[idx:].strip()
                # expect string or bool
                if rest.startswith('"'):
                    end = rest.find('"', 1)
                    if end != -1:
                        return rest[1:end]
                else:
                    # bool or null
                    if rest.startswith('true'):
                        return True
                    if rest.startswith('false'):
                        return False
                    if rest.startswith('null'):
                        return None
            return None

        def get_json_list(key):
            pattern = '"' + key + '":'
            if pattern in body:
                idx = body.index(pattern) + len(pattern)
                rest = body[idx:].strip()
                if rest.startswith('['):
                    end = rest.find("]", 0)
                    if end != -1:
                        inner = rest[1:end].strip()
                        # Simple list parsing
                        items = []
                        if inner:
                            # split by '{' to get objects
                            objs = inner.split('{')
                            for obj in objs[1:]:
                                # parse key:value pairs
                                o = {}
                                # simple approach: extract ip_address and mac_address
                                ip_pattern = '"ip_address":"'
                                if ip_pattern in obj:
                                    i = obj.index(ip_pattern) + len(ip_pattern)
                                    e = obj.find('"', i)
                                    if e != -1:
                                        o["ip_address"] = obj[i:e]
                                mac_pattern = '"mac_address":"'
                                if mac_pattern in obj:
                                    i = obj.index(mac_pattern) + len(mac_pattern)
                                    e = obj.find('"', i)
                                    if e != -1:
                                        o["mac_address"] = obj[i:e]
                                if o:
                                    items.append(o)
                        return items
            return []

        def get_json_list_dhcp(key):
            pattern = '"' + key + '":'
            if pattern in body:
                idx = body.index(pattern) + len(pattern)
                rest = body[idx:].strip()
                if rest.startswith('['):
                    end = rest.find("]", 0)
                    if end != -1:
                        inner = rest[1:end].strip()
                        items = []
                        if inner:
                            objs = inner.split('{')
                            for obj in objs[1:]:
                                o = {}
                                name_pattern = '"opt_name":"'
                                if name_pattern in obj:
                                    i = obj.index(name_pattern) + len(name_pattern)
                                    e = obj.find('"', i)
                                    if e != -1:
                                        o["name"] = obj[i:e]
                                val_pattern = '"opt_value":"'
                                if val_pattern in obj:
                                    i = obj.index(val_pattern) + len(val_pattern)
                                    e = obj.find('"', i)
                                    if e != -1:
                                        o["value"] = obj[i:e]
                                if o:
                                    items.append(o)
                        return items
            return []

        port = {
            "id": pid,
            "admin_state_up": get_json_str("admin_state_up"),
            "allowed_address_pairs": get_json_list("allowed_address_pairs"),
            "extra_dhcp_opts": get_json_list_dhcp("extra_dhcp_opts"),
            "ip_address": None,
            "name": get_json_str("name"),
            "security_groups": None,
            "subnet_id": subnet_id,
        }
        # Extract ip_address from fixed_ips
        fixed_ips = get_json_list("fixed_ips")
        if fixed_ips and len(fixed_ips) > 0:
            port["ip_address"] = fixed_ips[0].get("ip_address")
        # Extract security_groups
        sg_pattern = '"security_groups":'
        if sg_pattern in body:
            idx = body.index(sg_pattern) + len(sg_pattern)
            rest = body[idx:].strip()
            if rest.startswith('['):
                end = rest.find("]", 0)
                if end != -1:
                    inner = rest[1:end].strip()
                    if inner:
                        # extract strings
                        sgs = []
                        parts = inner.split('"')
                        for p in parts:
                            if len(p) == 36 and p.count("-") == 4:
                                sgs.append(p)
                        port["security_groups"] = sgs
        return port

    # Build create payload
    def build_create_payload():
        payload = {"port": {"network_id": subnet_id}}
        if params.get("name") != None:
            payload["port"]["name"] = params["name"]
        if params.get("admin_state_up") != None:
            payload["port"]["admin_state_up"] = params["admin_state_up"]
        if params.get("ip_address"):
            payload["port"]["fixed_ips"] = [{"ip_address": params["ip_address"]}]
        if params.get("security_groups"):
            payload["port"]["security_groups"] = params["security_groups"]
        # allowed_address_pairs
        if params.get("allowed_address_pairs"):
            pairs = []
            for pair in params["allowed_address_pairs"]:
                if pair.get("ip_address") or pair.get("mac_address"):
                    pairs.append({
                        "ip_address": pair.get("ip_address"),
                        "mac_address": pair.get("mac_address")
                    })
            if pairs:
                payload["port"]["allowed_address_pairs"] = pairs
        # extra_dhcp_opts
        if params.get("extra_dhcp_opts"):
            opts = []
            for opt in params["extra_dhcp_opts"]:
                if opt.get("name") or opt.get("value"):
                    o = {}
                    if opt.get("name"):
                        o["opt_name"] = opt["name"]
                    if opt.get("value"):
                        o["opt_value"] = opt["value"]
                    opts.append(o)
            if opts:
                payload["port"]["extra_dhcp_opts"] = opts
        return str(payload)

    # Build update payload
    def build_update_payload(current):
        payload = {"port": {}}
        changed = False
        if params.get("name") != None and current.get("name") != params["name"]:
            payload["port"]["name"] = params["name"]
            changed = True
        if params.get("admin_state_up") != None and current.get("admin_state_up") != params["admin_state_up"]:
            payload["port"]["admin_state_up"] = params["admin_state_up"]
            changed = True
        # allowed_address_pairs: compare lists (simple)
        if params.get("allowed_address_pairs"):
            pairs = []
            for pair in params["allowed_address_pairs"]:
                if pair.get("ip_address") or pair.get("mac_address"):
                    pairs.append({
                        "ip_address": pair.get("ip_address"),
                        "mac_address": pair.get("mac_address")
                    })
            if pairs != current.get("allowed_address_pairs", []):
                payload["port"]["allowed_address_pairs"] = pairs
                changed = True
        # extra_dhcp_opts: compare lists (simple)
        if params.get("extra_dhcp_opts"):
            opts = []
            for opt in params["extra_dhcp_opts"]:
                if opt.get("name") or opt.get("value"):
                    o = {}
                    if opt.get("name"):
                        o["opt_name"] = opt["name"]
                    if opt.get("value"):
                        o["opt_value"] = opt["value"]
                    opts.append(o)
            if opts != current.get("extra_dhcp_opts", []):
                payload["port"]["extra_dhcp_opts"] = opts
                changed = True
        # ip_address: cannot update directly; skip (only set at creation)
        # security_groups: compare
        if params.get("security_groups"):
            if params["security_groups"] != current.get("security_groups", []):
                payload["port"]["security_groups"] = params["security_groups"]
                changed = True
        if not changed:
            return None
        return str(payload)

    # Main logic
    if state == "present":
        if port_id:
            # Use provided ID
            current = read_port(port_id)
        else:
            # Search by name/subnet
            matches = search_port()
            if len(matches) > 1:
                fail("found multiple ports matching criteria")
            current = None
            if len(matches) == 1:
                current = read_port(matches[0]["id"])

        if not current:
            # Create
            if ctx.check_mode:
                return {"changed": True, "msg": "would create port"}
            payload = build_create_payload()
            res = vpc_request("POST", "/ports", payload)
            body = res.stdout
            # Extract id from response
            id_start = body.find('"id":"') + len('"id":"')
            if id_start >= len('"id":"'):
                port_id = body[id_start:id_start+36]
                if port_id.find('"') != -1:
                    port_id = port_id[:port_id.index('"')]
            else:
                fail("could not extract port id from creation response")
            return {"changed": True, "msg": "port created", "data": {"id": port_id}}

        # Update if needed
        update_payload = build_update_payload(current)
        if update_payload:
            if ctx.check_mode:
                return {"changed": True, "msg": "would update port"}
            res = vpc_request("PUT", "/ports/" + port_id, update_payload)
            return {"changed": True, "msg": "port updated", "data": {"id": port_id}}

        return {"changed": False, "msg": "port already exists", "data": {"id": port_id}}

    if state == "absent":
        if not port_id:
            matches = search_port()
            if len(matches) > 1:
                fail("found multiple ports matching criteria")
            if len(matches) == 1:
                port_id = matches[0]["id"]

        if not port_id:
            return {"changed": False, "msg": "port not found"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete port"}

        res = vpc_request("DELETE", "/ports/" + port_id)
        return {"changed": True, "msg": "port deleted"}

    fail("unsupported state: " + state)
