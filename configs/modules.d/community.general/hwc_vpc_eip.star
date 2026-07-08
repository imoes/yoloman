def main(ctx, params):
    # Required parameters
    user = params["user"]
    password = params["password"]
    domain = params["domain"]
    project = params["project"]
    identity_endpoint = params["identity_endpoint"]
    region = params.get("region")
    state = params.get("state", "present")
    timeouts = params.get("timeouts", {})
    create_timeout = timeouts.get("create", "5m").rstrip("m")
    update_timeout = timeouts.get("update", "5m").rstrip("m")

    # Resource parameters
    eip_type = params["type"]
    dedicated_bw = params.get("dedicated_bandwidth")
    shared_bw_id = params.get("shared_bandwidth_id")
    enterprise_project_id = params.get("enterprise_project_id")
    ip_version = params.get("ip_version")
    ipv4_address = params.get("ipv4_address")
    port_id = params.get("port_id")
    eip_id = params.get("id")

    # Build auth header
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

    # Discover region if not provided
    if region == None:
        fail("region is required")
    auth_url = identity_endpoint.rstrip("/") + "/v3/auth/tokens"
    res = ctx.run(["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
                   "-d", str(auth_body).replace("'", "\""), auth_url])
    if res.rc != 0:
        fail("authentication failed: " + res.stderr)
    token = ""
    for line in res.stdout.split("\n"):
        if line.startswith("X-Subject-Token:"):
            token = line.split(":", 1)[1].strip()
            break
    if token == "":
        fail("failed to extract auth token")

    headers = ["-H", "X-Auth-Token: " + token, "-H", "Content-Type: application/json"]

    # Helper: build URL for vpc api
    def build_url(suffix):
        return "https://vpc." + region + ".myhwclouds.com/v1/" + project + suffix

    # Helper: run api request
    def run_api(method, path, data=None, mutates=False):
        args = ["curl", "-s", "-X", method] + headers
        if data:
            args += ["-d", str(data).replace("'", "\"")]
        args.append(path)
        res = ctx.run(args, mutates=mutates)
        if res.rc != 0:
            fail("api error on " + method + " " + path + ": " + res.stderr)
        return res

    # Search existing EIP by identity fields
    def search_eip():
        url = build_url("/publicips")
        res = run_api("GET", url)
        if res.rc != 0:
            fail("search resource failed: " + res.stderr)
        body = res.stdout.strip()
        if body == "":
            return []
        # Parse JSON manually (no json module)
        items = []
        # Find the publicips array
        start = body.find('"publicips"')
        if start == -1:
            return []
        start = body.find("[", start)
        end = body.rfind("]")
        if start == -1 or end == -1 or end <= start:
            return []
        list_str = body[start+1:end].strip()
        if list_str == "":
            return []
        # Split by },{ pattern (naive)
        for segment in list_str.split("}, {"):
            # Clean braces
            segment = segment.strip().strip("{}")
            item = {}
            for part in segment.split(", "):
                if ":" in part:
                    k, v = part.split(":", 1)
                    k = k.strip().strip('"')
                    v = v.strip().strip('"')
                    item[k] = v
            if "id" in item:
                items.append(item)
        return items

    # Get EIP by ID
    def get_eip(eip_id):
        url = build_url("/publicips/" + eip_id)
        res = run_api("GET", url)
        if res.rc != 0:
            return None
        body = res.stdout.strip().strip("{}")
        result = {}
        for part in body.split(", "):
            if ":" in part:
                k, v = part.split(":", 1)
                k = k.strip().strip('"')
                v = v.strip().strip('"')
                result[k] = v
        return result

    # Build create payload
    def build_create_body():
        body = {}
        # bandwidth
        if dedicated_bw != None and shared_bw_id != None:
            fail("dedicated_bandwidth and shared_bandwidth_id cannot be set at same time")
        if dedicated_bw != None:
            body["bandwidth"] = {
                "charge_mode": dedicated_bw["charge_mode"],
                "name": dedicated_bw["name"],
                "share_type": "PER",
                "size": dedicated_bw["size"]
            }
        elif shared_bw_id != None:
            body["bandwidth"] = {
                "id": shared_bw_id,
                "share_type": "WHOLE"
            }
        else:
            fail("must provide dedicated_bandwidth or shared_bandwidth_id")

        if enterprise_project_id != None:
            body["enterprise_project_id"] = enterprise_project_id

        # publicip
        publicip = {}
        if ipv4_address != None:
            publicip["ip_address"] = ipv4_address
        if ip_version != None:
            publicip["ip_version"] = str(ip_version)
        publicip["type"] = eip_type
        body["publicip"] = publicip

        return body

    # Check if current and desired state match
    def match_desired(current):
        if current == None:
            return False
        # Compare key fields
        if current.get("type") != eip_type:
            return False
        if enterprise_project_id != None and current.get("enterprise_project_id") != enterprise_project_id:
            return False
        # Bandwidth comparison (simplified)
        current_bw = current.get("bandwidth_share_type", "")
        if dedicated_bw != None:
            if current_bw != "PER":
                return False
        if shared_bw_id != None:
            if current_bw != "WHOLE":
                return False
        # Optional fields
        if ip_version != None and str(ip_version) != current.get("ip_version", ""):
            return False
        if ipv4_address != None and ipv4_address != current.get("public_ip_address", ""):
            return False
        if port_id != None and port_id != current.get("port_id", ""):
            return False

        return True

    # Perform action based on state
    changed = False
    result = {}

    if state == "present":
        # Check existence
        if eip_id != None:
            resource = get_eip(eip_id)
        else:
            items = search_eip()
            # Filter by identity fields
            candidates = [i for i in items if i.get("type") == eip_type and
                          (enterprise_project_id == None or i.get("enterprise_project_id") == enterprise_project_id) and
                          (shared_bw_id != None or dedicated_bw != None)]
            if len(candidates) > 1:
                fail("Found more than one matching EIP")
            resource = candidates[0] if candidates else None
            if resource != None:
                eip_id = resource.get("id")
                params["id"] = eip_id

        if resource == None:
            # Create
            if ctx.check_mode:
                return {"changed": True, "msg": "would create new EIP"}
            create_body = build_create_body()
            url = build_url("/publicips")
            res = run_api("POST", url, create_body, mutates=True)
            body = res.stdout.strip()
            # Extract id
            start = body.find('"id"')
            if start == -1:
                fail("failed to extract EIP ID from create response")
            start = body.find('"', start+3)
            end = body.find('"', start+1)
            if end == -1:
                fail("failed to extract EIP ID from create response")
            eip_id = body[start+1:end]
            params["id"] = eip_id
            changed = True
            # Poll until active
            timeout_sec = int(create_timeout) * 60
            # Simplified polling loop (fixed iterations for brevity)
            for _ in range(min(timeout_sec // 5, 60)):
                resource = get_eip(eip_id)
                if resource != None and resource.get("status") in ["ACTIVE", "DOWN"]:
                    break
        else:
            # Check if update needed
            if not match_desired(resource):
                # Update
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update existing EIP"}
                # Build update payload (simplified)
                update_body = {"publicip": {}}
                if port_id != None and port_id != resource.get("port_id", ""):
                    update_body["publicip"]["port_id"] = port_id
                if ip_version != None and str(ip_version) != resource.get("ip_version", ""):
                    update_body["publicip"]["ip_version"] = str(ip_version)
                if update_body["publicip"] == {}:
                    fail("no updatable fields changed")
                url = build_url("/publicips/" + eip_id)
                res = run_api("PUT", url, update_body, mutates=True)
                changed = True
                # Poll until active
                timeout_sec = int(update_timeout) * 60
                for _ in range(min(timeout_sec // 5, 60)):
                    resource = get_eip(eip_id)
                    if resource != None and resource.get("status") in ["ACTIVE", "DOWN"]:
                        break
            else:
                # Already in desired state
                pass

        # Read final resource
        if resource == None:
            resource = get_eip(eip_id)
        # Build return dict
        result = {
            "type": resource.get("type", ""),
            "enterprise_project_id": resource.get("enterprise_project_id", ""),
            "ipv4_address": resource.get("public_ip_address", ""),
            "ipv6_address": resource.get("public_ipv6_address", ""),
            "port_id": resource.get("port_id", ""),
            "create_time": resource.get("create_time", ""),
            "private_ip_address": resource.get("private_ip_address", ""),
            "ip_version": int(resource.get("ip_version", "0")) if resource.get("ip_version", "0").isdigit() else None,
            "shared_bandwidth_id": resource.get("bandwidth_id", "") if resource.get("bandwidth_share_type", "") == "WHOLE" else "",
            "dedicated_bandwidth": None,
            "id": eip_id
        }
        # Build dedicated_bandwidth if applicable
        if resource.get("bandwidth_share_type") == "PER":
            result["dedicated_bandwidth"] = {
                "name": resource.get("bandwidth_name", ""),
                "size": int(resource.get("bandwidth_size", "0")) if resource.get("bandwidth_size", "0").isdigit() else None,
                "charge_mode": "",  # Not available in read response
                "id": resource.get("bandwidth_id", "")
            }

    else:  # state == absent
        # Check existence
        if eip_id != None:
            resource = get_eip(eip_id)
        else:
            items = search_eip()
            candidates = [i for i in items if i.get("type") == eip_type and
                          (enterprise_project_id == None or i.get("enterprise_project_id") == enterprise_project_id)]
            if len(candidates) > 1:
                fail("Found more than one matching EIP")
            resource = candidates[0] if candidates else None
            if resource != None:
                eip_id = resource.get("id")
                params["id"] = eip_id

        if resource != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete existing EIP"}
            # Unbind port first if bound
            if resource.get("port_id", "") != "":
                # Unbind by setting port_id to empty
                url = build_url("/publicips/" + eip_id)
                update_body = {"publicip": {"port_id": ""}}
                res = run_api("PUT", url, update_body, mutates=True)
                # Wait for unbind (simplified)
            # Delete
            url = build_url("/publicips/" + eip_id)
            res = run_api("DELETE", url, mutates=True)
            changed = True
            # Wait for delete
            for _ in range(30):
                res2 = run_api("GET", url)
                if res2.rc != 0:
                    break

    if changed:
        return {"changed": True, "msg": "resource updated", "data": result}
    else:
        return {"changed": False, "msg": "resource already in desired state", "data": result}
