def main(ctx, params):
    name = params["name"]
    cidr = params["cidr"]
    state = params.get("state", "present")
    domain = params["domain"]
    identity_endpoint = params["identity_endpoint"]
    project = params["project"]
    user = params["user"]
    password = params["password"]
    region = params.get("region")
    timeouts = params.get("timeouts", {})

    # Validate required params
    if name == "":
        fail("name is required")
    if cidr == "":
        fail("cidr is required")
    if domain == "":
        fail("domain is required")
    if identity_endpoint == "":
        fail("identity_endpoint is required")
    if project == "":
        fail("project is required")
    if user == "":
        fail("user is required")
    if password == "":
        fail("password is required")

    # Get region from facts if not specified
    if region == None or region == "":
        facts = ctx.facts()
        region = facts.get("region", "")

    # Build auth header: Basic base64(user:password)
    auth_raw = user + ":" + password
    res = ctx.run(["printf", "%s" % auth_raw, "|", "base64", "-w", "0"])
    if res.rc != 0:
        fail("failed to base64 encode credentials: " + res.stderr)
    auth_token = res.stdout.strip()
    auth_header = "Basic " + auth_token

    def vpc_list_url():
        base = identity_endpoint + "/v1/" + project + "/vpcs"
        if region != "":
            return base + "?region=" + region
        return base

    def vpc_url(vpc_id):
        base = identity_endpoint + "/v1/" + project + "/vpcs/" + vpc_id
        if region != "":
            return base + "?region=" + region
        return base

    def find_vpc_id_by_name():
        url = vpc_list_url()
        headers = ["-H", "Authorization: " + auth_header,
                   "-H", "Domain-Name: " + domain,
                   "-H", "Content-Type: application/json"]
        res = ctx.run(["curl", "-s", "-f", "-X", "GET"] + headers + [url])
        if res.rc != 0:
            return None
        stdout = res.stdout
        key = '"vpcs"'
        idx = stdout.find(key)
        if idx == -1:
            return None
        start = stdout.find("[", idx)
        if start == -1:
            return None
        depth = 0
        end = start
        for i in range(start, len(stdout)):
            if stdout[i] == '[':
                depth += 1
            elif stdout[i] == ']':
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if depth != 0:
            return None
        vpcs_str = stdout[start:end+1]
        ids = []
        obj_start = 0
        while True:
            brace_start = vpcs_str.find("{", obj_start)
            if brace_start == -1:
                break
            brace_end = vpcs_str.find("}", brace_start)
            if brace_end == -1:
                break
            obj = vpcs_str[brace_start:brace_end+1]
            id_key = '"id"'
            name_key = '"name"'
            id_idx = obj.find(id_key)
            name_idx = obj.find(name_key)
            if id_idx == -1 or name_idx == -1:
                obj_start = brace_end + 1
                continue
            id_val_start = obj.find('"', id_idx + len(id_key))
            if id_val_start == -1:
                obj_start = brace_end + 1
                continue
            id_val_start += 1
            id_val_end = obj.find('"', id_val_start)
            if id_val_end == -1:
                obj_start = brace_end + 1
                continue
            obj_id = obj[id_val_start:id_val_end]
            name_val_start = obj.find('"', name_idx + len(name_key))
            if name_val_start == -1:
                obj_start = brace_end + 1
                continue
            name_val_start += 1
            name_val_end = obj.find('"', name_val_start)
            if name_val_end == -1:
                obj_start = brace_end + 1
                continue
            obj_name = obj[name_val_start:name_val_end]
            if obj_name == name:
                ids.append(obj_id)
            obj_start = brace_end + 1
        if len(ids) == 0:
            return None
        if len(ids) > 1:
            fail("Multiple VPCs named " + name + " found")
        return ids[0]

    vpc_id = params.get("id")
    if vpc_id == None or vpc_id == "":
        vpc_id = find_vpc_id_by_name()

    def fetch_vpc(vpc_id):
        if vpc_id == None or vpc_id == "":
            return None
        url = vpc_url(vpc_id)
        headers = ["-H", "Authorization: " + auth_header,
                   "-H", "Domain-Name: " + domain,
                   "-H", "Content-Type: application/json"]
        res = ctx.run(["curl", "-s", "-f", "-X", "GET"] + headers + [url])
        if res.rc == 404 or ((res.rc == 0) == False):
            return None
        if res.rc != 0:
            fail("failed to fetch VPC " + vpc_id + ": " + res.stderr)
        stdout = res.stdout
        vpc_key = '"vpc"'
        idx = stdout.find(vpc_key)
        if idx == -1:
            return None
        start = stdout.find("{", idx + len(vpc_key))
        if start == -1:
            return None
        depth = 0
        end = start
        for i in range(start, len(stdout)):
            if stdout[i] == '{':
                depth += 1
            elif stdout[i] == '}':
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if depth != 0:
            return None
        obj_str = stdout[start:end+1]
        def get_str(obj, key):
            idx = obj.find('"' + key + '"')
            if idx == -1:
                return ""
            start = obj.find('"', idx + len(key) + 2)
            if start == -1:
                return ""
            start += 1
            end = obj.find('"', start)
            if end == -1:
                return ""
            return obj[start:end]
        return {
            "id": get_str(obj_str, "id"),
            "name": get_str(obj_str, "name"),
            "cidr": get_str(obj_str, "cidr"),
            "status": get_str(obj_str, "status")
        }

    current = fetch_vpc(vpc_id)

    if state == "present":
        if current != None:
            if ((current["cidr"] != cidr) or (current["name"] != name)):
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update VPC " + vpc_id}
                update_body = '{"vpc":{"name":"' + name + '","cidr":"' + cidr + '"}}'
                url = vpc_url(vpc_id)
                headers = ["-H", "Authorization: " + auth_header,
                           "-H", "Domain-Name: " + domain,
                           "-H", "Content-Type: application/json"]
                res = ctx.run(["curl", "-s", "-f", "-X", "PUT",
                               "-d", update_body] + headers + [url])
                if res.rc != 0:
                    fail("failed to update VPC " + vpc_id + ": " + res.stderr)
                return {"changed": True, "id": vpc_id, "name": name, "cidr": cidr,
                        "msg": "updated VPC " + vpc_id}
            return {"changed": False, "id": current["id"], "name": current["name"],
                    "cidr": current["cidr"], "msg": "VPC already exists"}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create VPC " + name}
            create_body = '{"vpc":{"name":"' + name + '","cidr":"' + cidr + '"}}'
            url = vpc_list_url()
            headers = ["-H", "Authorization: " + auth_header,
                       "-H", "Domain-Name: " + domain,
                       "-H", "Content-Type: application/json"]
            res = ctx.run(["curl", "-s", "-f", "-X", "POST",
                           "-d", create_body] + headers + [url])
            if res.rc != 0:
                fail("failed to create VPC: " + res.stderr)
            stdout = res.stdout
            vpc_key = '"vpc"'
            idx = stdout.find(vpc_key)
            if idx == -1:
                fail("missing 'vpc' in create response")
            start = stdout.find("{", idx + len(vpc_key))
            if start == -1:
                fail("invalid JSON in create response")
            depth = 0
            end = start
            for i in range(start, len(stdout)):
                if stdout[i] == '{':
                    depth += 1
                elif stdout[i] == '}':
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            if depth != 0:
                fail("invalid JSON in create response")
            obj_str = stdout[start:end+1]
            def get_str(obj, key):
                idx = obj.find('"' + key + '"')
                if idx == -1:
                    return ""
                start = obj.find('"', idx + len(key) + 2)
                if start == -1:
                    return ""
                start += 1
                end = obj.find('"', start)
                if end == -1:
                    return ""
                return obj[start:end]
            created_id = get_str(obj_str, "id")
            created_name = get_str(obj_str, "name")
            created_cidr = get_str(obj_str, "cidr")
            return {"changed": True, "id": created_id, "name": created_name,
                    "cidr": created_cidr, "msg": "created VPC " + created_id}
    else:
        if current == None:
            return {"changed": False, "msg": "VPC not found"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete VPC " + vpc_id}
        url = vpc_url(vpc_id)
        headers = ["-H", "Authorization: " + auth_header,
                   "-H", "Domain-Name: " + domain,
                   "-H", "Content-Type: application/json"]
        res = ctx.run(["curl", "-s", "-f", "-X", "DELETE"] + headers + [url])
        if res.rc != 0:
            fail("failed to delete VPC " + vpc_id + ": " + res.stderr)
        return {"changed": True, "msg": "deleted VPC " + vpc_id}
