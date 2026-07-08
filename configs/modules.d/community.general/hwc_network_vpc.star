def main(ctx, params):
    name = params["name"]
    cidr = params["cidr"]
    state = params.get("state", "present")
    domain = params["domain"]
    identity_endpoint = params["identity_endpoint"]
    project = params["project"]
    user = params["user"]
    password = params["password"]
    region = params.get("region", "")
    timeouts = params.get("timeouts", {})
    vpc_id = params.get("id")

    # Compute timeouts (default 15 minutes)
    def parse_timeout(timeout_str):
        if timeout_str.endswith("m"):
            return int(timeout_str[:-1]) * 60
        return 60  # fallback to 60s if invalid

    create_timeout = parse_timeout(timeouts.get("create", "15m"))
    delete_timeout = parse_timeout(timeouts.get("delete", "15m"))

    # Build auth token endpoint
    auth_url = identity_endpoint.rstrip("/") + "/v3/auth/tokens"

    # Authenticate to get token and project_id
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

    # Get auth token using ctx.run (no external libraries)
    res = ctx.run([
        "curl", "-s", "-X", "POST", auth_url,
        "-H", "Content-Type: application/json",
        "-d", str(auth_body)
    ])
    if res.rc != 0:
        fail("authentication failed: " + res.stderr)

    # Extract token from response headers
    headers = res.stderr if res.stderr else ""
    token = ""
    for line in headers.split("\n"):
        if line.lower().startswith("x-subject-token:"):
            parts = line.split(":", 1)
            if len(parts) == 2:
                token = parts[1].strip()
            break

    if not token:
        fail("authentication failed: token not found")

    # Determine region and build base URL
    base_url = identity_endpoint.rstrip("/")
    if region:
        base_url = base_url.replace("identity", "vpc/" + region)
    else:
        base_url = base_url.replace("identity", "vpc")

    # Build VPC endpoint
    vpc_url = base_url + "/v1/" + project + "/vpcs"

    # If id not provided, search by name
    if not vpc_id and name:
        # List all VPCs with pagination
        marker = ""
        found_ids = []
        for _ in range(10):  # safe iteration limit
            list_url = vpc_url
            if marker:
                list_url = vpc_url + "?marker=" + marker
            res = ctx.run(["curl", "-s", "-X", "GET", list_url,
                          "-H", "X-Auth-Token: " + token])
            if res.rc != 0:
                fail("failed to list VPCs: " + res.stderr)

            # Parse VPC entries manually from JSON
            data = res.stdout
            if '"vpcs"' not in data:
                break

            # Extract vpcs array content
            vpcs_start = data.find('"vpcs"') + 7
            vpcs_end = data.find(']', vpcs_start)
            if vpcs_end == -1:
                break
            vpcs_content = data[vpcs_start:vpcs_end+1]

            # Parse individual VPC objects
            idx = 0
            while '"id"' in vpcs_content[idx:]:
                obj_start = vpcs_content.find("{", idx)
                if obj_start == -1:
                    break
                obj_end = vpcs_content.find("}", obj_start)
                if obj_end == -1:
                    break
                obj_str = vpcs_content[obj_start:obj_end+1]

                # Extract name and id
                name_key = '"name"'
                id_key = '"id"'
                if name_key in obj_str and id_key in obj_str:
                    name_pos = obj_str.find(name_key) + len(name_key) + 1
                    name_end = obj_str.find('"', name_pos)
                    line_name = obj_str[name_pos:name_end]

                    id_pos = obj_str.find(id_key) + len(id_key) + 1
                    id_end = obj_str.find('"', id_pos)
                    line_id = obj_str[id_pos:id_end]

                    if line_name == name:
                        found_ids.append(line_id)

                idx = obj_end + 1

            # Check for pagination marker
            next_marker_key = '"markers"'
            if next_marker_key in data:
                next_marker_start = data.find(next_marker_key) + len(next_marker_key) + 2
                next_marker_end = data.find('"', next_marker_start)
                if next_marker_end != -1:
                    marker = data[next_marker_start:next_marker_end]
                    if not marker:
                        break
                else:
                    break
            else:
                break

        if len(found_ids) > 1:
            fail("multiple VPCs found with name: " + name)
        elif len(found_ids) == 1:
            vpc_id = found_ids[0]
        else:
            vpc_id = None

    # Fetch existing VPC by id
    existing = None
    if vpc_id:
        res = ctx.run(["curl", "-s", "-X", "GET", vpc_url + "/" + vpc_id,
                      "-H", "X-Auth-Token: " + token])
        if res.rc == 0 and '"vpc"' in res.stdout:
            existing = res.stdout

    changed = False
    result = {}

    if existing and state == "present":
        # Check if cidr differs
        if '"cidr"' in existing:
            cidr_key_pos = existing.find('"cidr"') + 7
            cidr_end = existing.find('"', cidr_key_pos)
            current_cidr = existing[cidr_key_pos:cidr_end]
            if current_cidr == cidr:
                result = {
                    "changed": False,
                    "msg": "VPC already exists with correct configuration"
                }
                return result
        # Update needed
        if ctx.check_mode:
            return {"changed": True, "msg": "would update VPC " + name}
        update_body = '{"vpc":{"cidr":"' + cidr + '"}}'
        res = ctx.run([
            "curl", "-s", "-X", "PUT", vpc_url + "/" + vpc_id,
            "-H", "X-Auth-Token: " + token,
            "-H", "Content-Type: application/json",
            "-d", update_body
        ])
        if res.rc != 0:
            fail("failed to update VPC: " + res.stderr)
        changed = True
        result = {
            "changed": True,
            "msg": "updated VPC " + name
        }

    elif not existing and state == "present":
        if ctx.check_mode:
            return {"changed": True, "msg": "would create VPC " + name}
        create_body = '{"vpc":{"name":"' + name + '","cidr":"' + cidr + '"}}'
        res = ctx.run([
            "curl", "-s", "-X", "POST", vpc_url,
            "-H", "X-Auth-Token: " + token,
            "-H", "Content-Type: application/json",
            "-d", create_body
        ])
        if res.rc != 0:
            fail("failed to create VPC: " + res.stderr)
        changed = True
        data = res.stdout
        if '"vpc"' in data:
            id_pos = data.find('"id"') + 5
            id_end = data.find('"', id_pos)
            vpc_id = data[id_pos:id_end]
            result["id"] = vpc_id
        result = {
            "changed": True,
            "msg": "created VPC " + name
        }

    elif existing and state == "absent":
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete VPC " + name}
        res = ctx.run([
            "curl", "-s", "-X", "DELETE", vpc_url + "/" + vpc_id,
            "-H", "X-Auth-Token: " + token
        ])
        if res.rc != 0:
            fail("failed to delete VPC: " + res.stderr)
        changed = True
        result = {
            "changed": True,
            "msg": "deleted VPC " + name
        }

    else:  # not existing and state == "absent"
        result = {
            "changed": False,
            "msg": "VPC does not exist"
        }

    result["changed"] = changed
    if vpc_id:
        result["id"] = vpc_id
    result["name"] = name
    result["cidr"] = cidr
    return result
