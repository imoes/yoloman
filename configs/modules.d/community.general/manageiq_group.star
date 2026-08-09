def main(ctx, params):
    description = params["description"]
    state = params.get("state", "present")
    role_id = params.get("role_id")
    role = params.get("role")
    tenant_id = params.get("tenant_id")
    tenant = params.get("tenant")
    managed_filters = params.get("managed_filters")
    managed_filters_merge_mode = params.get("managed_filters_merge_mode", "replace")
    belongsto_filters = params.get("belongsto_filters")
    belongsto_filters_merge_mode = params.get("belongsto_filters_merge_mode", "replace")

    # Validate required fields
    if description == None:
        fail("description is required")

    # Build ManageIQ connection URL
    conn = params.get("manageiq_connection") or {}
    url = conn.get("url")
    username = conn.get("username")
    password = conn.get("password")
    token = conn.get("token")

    # Use environment variables as fallbacks
    if url == None:
        res = ctx.run(["sh", "-c", "echo $MIQ_URL"])
        url = res.stdout.strip()
    if username == None:
        res = ctx.run(["sh", "-c", "echo $MIQ_USERNAME"])
        username = res.stdout.strip()
    if password == None:
        res = ctx.run(["sh", "-c", "echo $MIQ_PASSWORD"])
        password = res.stdout.strip()
    if token == None:
        res = ctx.run(["sh", "-c", "echo $MIQ_TOKEN"])
        token = res.stdout.strip()

    # Basic auth or token auth required
    if token == None and (username == None or password == None):
        fail("manageiq_connection requires either token or both username and password")

    # Prepare headers
    headers = {"Content-Type": "application/json"}
    if token != None:
        headers["X-Auth-Token"] = token
    else:
        # Build base64 manually (simple implementation)
        auth_str = username + ":" + password
        # Base64 chars mapping for manual encoding (ASCII only)
        b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        # Simple base64 implementation
        def base64_encode(s):
            result = ""
            i = 0
            while i < len(s):
                c1 = ord(s[i])
                i += 1
                c2 = ord(s[i]) if i < len(s) else 0
                i += 1
                c3 = ord(s[i]) if i < len(s) else 0
                i += 1
                result += b64_chars[(c1 >> 2) & 0x3F]
                result += b64_chars[((c1 & 3) << 4) | (c2 >> 4)]
                if i - 2 < len(s):
                    result += b64_chars[((c2 & 0x0F) << 2) | (c3 >> 6)]
                else:
                    result += "="
                if i - 1 < len(s):
                    result += b64_chars[c3 & 0x3F]
                else:
                    result += "="
            return result
        headers["Authorization"] = "Basic " + base64_encode(auth_str)

    # Helper to call ManageIQ API
    def miq_get(path):
        cmd = ["curl", "-s", "-X", "GET", "-H", "Content-Type: application/json", url + path]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("curl failed for " + url + path + ": " + res.stderr)
        return res.stdout.strip()

    def miq_post(path, payload):
        # Escape double quotes in payload
        escaped = payload.replace('"', '\\"')
        cmd = ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", url + path, "-d", '"' + escaped + '"']
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("curl POST failed for " + url + path + ": " + res.stderr)
        return res.stdout.strip()

    # Check if group exists by description
    group = None
    query = url + "/api/groups?expand=resources&filter[]=description=" + description
    res = ctx.run(["curl", "-s", "-X", "GET", "-H", "Content-Type: application/json", query])
    if res.rc != 0:
        fail("Failed to query groups: " + res.stderr)
    output = res.stdout.strip()
    # Naive parsing for single group with matching description
    if output.find('"description"') != -1 and output.find(description) != -1:
        # Extract first group id
        id_start = output.find('"id":')
        if id_start != -1:
            rest = output[id_start + 5:]
            id_val = ""
            for c in rest:
                if c.isdigit():
                    id_val += c
                else:
                    break
            if id_val != "":
                group = {"id": int(id_val), "description": description}

    # State absent
    if state == "absent":
        if group != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete group " + description}
            res = ctx.run(["curl", "-s", "-X", "POST",
                           "-H", "Content-Type: application/json",
                           url + "/api/groups/" + str(group["id"]),
                           "-d", '{"action":"delete"}'])
            if res.rc != 0:
                fail("Failed to delete group " + description + ": " + res.stderr)
            return {"changed": True, "msg": "deleted group " + description}
        else:
            return {"changed": False, "msg": "group '%s' does not exist" % description}

    # State present
    if state == "present":
        # Resolve tenant
        tenant_obj = None
        if tenant_id != None:
            if ctx.check_mode:
                tenant_obj = {"id": tenant_id}
            else:
                res = ctx.run(["curl", "-s", "-X", "GET",
                               "-H", "Content-Type: application/json",
                               url + "/api/tenants/" + str(tenant_id)])
                if res.rc != 0:
                    fail("Tenant with id " + str(tenant_id) + " not found")
                tenant_obj = {"id": tenant_id}
        elif tenant != None:
            if ctx.check_mode:
                tenant_obj = {"name": tenant}
            else:
                res = ctx.run(["curl", "-s", "-X", "GET",
                               "-H", "Content-Type: application/json",
                               url + "/api/tenants?expand=resources&filter[]=name=" + tenant])
                if res.rc != 0 or res.stdout.find('"id"') == -1:
                    fail("Tenant '%s' not found" % tenant)
                tenant_obj = {"name": tenant}
        # Resolve role
        role_obj = None
        if role_id != None:
            if ctx.check_mode:
                role_obj = {"id": role_id}
            else:
                res = ctx.run(["curl", "-s", "-X", "GET",
                               "-H", "Content-Type: application/json",
                               url + "/api/roles/" + str(role_id)])
                if res.rc != 0:
                    fail("Role with id " + str(role_id) + " not found")
                role_obj = {"id": role_id}
        elif role != None:
            if ctx.check_mode:
                role_obj = {"name": role}
            else:
                res = ctx.run(["curl", "-s", "-X", "GET",
                               "-H", "Content-Type: application/json",
                               url + "/api/roles?expand=resources&filter[]=name=" + role])
                if res.rc != 0 or res.stdout.find('"id"') == -1:
                    fail("Role '%s' not found" % role)
                role_obj = {"name": role}

        # Create or update
        if group != None:
            # Update logic
            if ctx.check_mode:
                return {"changed": True, "msg": "would update group " + description}
            # Build update payload
            update_payload = '{"description":"' + description + '"}'
            if role_obj != None and role_obj.get("id") != None:
                update_payload = update_payload.replace('"description"', '"role":{"id":%s},"description"' % str(role_obj["id"]))
            if tenant_obj != None and tenant_obj.get("id") != None:
                update_payload = update_payload.replace('"role"', '"tenant":{"id":%s},"role"' % str(tenant_obj["id"]))
            res = ctx.run(["curl", "-s", "-X", "POST",
                           "-H", "Content-Type: application/json",
                           url + "/api/groups/" + str(group["id"]),
                           "-d", update_payload])
            if res.rc != 0:
                fail("Failed to update group " + description)
            return {"changed": True, "msg": "updated group " + description}
        else:
            # Create logic
            if ctx.check_mode:
                return {"changed": True, "msg": "would create group " + description}
            create_payload = '{"description":"' + description + '"}'
            if role_obj != None and role_obj.get("id") != None:
                create_payload = create_payload.replace('"description"', '"role":{"id":%s},"description"' % str(role_obj["id"]))
            if tenant_obj != None and tenant_obj.get("id") != None:
                create_payload = create_payload.replace('"role"', '"tenant":{"id":%s},"role"' % str(tenant_obj["id"]))
            res = ctx.run(["curl", "-s", "-X", "POST",
                           "-H", "Content-Type: application/json",
                           url + "/api/groups",
                           "-d", create_payload])
            if res.rc != 0:
                fail("Failed to create group " + description + ": " + res.stderr)
            # Extract new group id from response
            output = res.stdout.strip()
            id_str = ""
            if output.find('"id":') != -1:
                idx = output.find('"id":') + 5
                while idx < len(output) and output[idx].isdigit():
                    id_str += output[idx]
                    idx += 1
            if id_str == "":
                fail("Failed to parse created group id")
            return {"changed": True, "msg": "created group " + description}
