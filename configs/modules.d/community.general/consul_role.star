def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    token = params.get("token")
    ca_path = params.get("ca_path")
    validate_certs = params.get("validate_certs", True)
    description = params.get("description")
    policies = params.get("policies")
    templated_policies = params.get("templated_policies")
    service_identities = params.get("service_identities")
    node_identities = params.get("node_identities")

    base_url = "%s://%s:%d" % (scheme, host, port)
    headers = {}
    if token:
        headers["X-Consul-Token"] = token

    # Helper to build query for role lookup
    def build_request(method, path, json_data=None):
        args = ["curl", "-s", "-X", method]
        args.extend(["-H", "Content-Type: application/json"])
        for k, v in headers.items():
            args.extend(["-H", "%s: %s" % (k, v)])
        if not validate_certs:
            args.append("-k")
        if ca_path:
            args.extend(["--cacert", ca_path])
        args.append(base_url + path)
        if json_data != None:
            # Simple JSON stringification for curl body
            args.extend(["--data", json_data])
        return args

    # Step 1: Get current role
    get_args = build_request("GET", "/v1/acl/role/name/%s" % name)
    res = ctx.run(get_args)
    role = None
    if res.rc == 0 and len(res.stdout.strip()) > 0:
        role = res.stdout.strip()
    elif res.rc != 0 and "404" not in res.stderr:
        fail("failed to lookup role %s: %s" % (name, res.stderr))

    # Handle absent state
    if state == "absent":
        if role == None:
            return {"changed": False, "msg": "role %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete role %s" % name}
        delete_args = build_request("DELETE", "/v1/acl/role/%s" % name.replace('"', '\\"'))
        res = ctx.run(delete_args)
        if res.rc != 0:
            fail("failed to delete role %s: %s" % (name, res.stderr))
        return {"changed": True, "msg": "deleted role %s" % name}

    # present state
    if role == None:
        # Create new role
        payload = {"Name": name}
        if description != None:
            payload["Description"] = description
        if policies != None:
            payload["Policies"] = []
            for p in policies:
                item = {}
                if "id" in p:
                    item["ID"] = p["id"]
                if "name" in p:
                    item["Name"] = p["name"]
                payload["Policies"].append(item)
        if templated_policies != None:
            payload["TemplatedPolicies"] = []
            for tp in templated_policies:
                item = {"TemplateName": tp["template_name"]}
                if "template_variables" in tp:
                    item["TemplateVariables"] = tp["template_variables"]
                payload["TemplatedPolicies"].append(item)
        if service_identities != None:
            payload["ServiceIdentities"] = []
            for si in service_identities:
                item = {"ServiceName": si["service_name"]}
                if "datacenters" in si:
                    item["Datacenters"] = si["datacenters"]
                payload["ServiceIdentities"].append(item)
        if node_identities != None:
            payload["NodeIdentities"] = []
            for ni in node_identities:
                item = {"NodeName": ni["node_name"], "Datacenter": ni["datacenter"]}
                payload["NodeIdentities"].append(item)

        # Build JSON manually to avoid dict str() issues
        def to_json(obj):
            if type(obj) == "dict":
                items = []
                for k, v in obj.items():
                    items.append('"%s": %s' % (k, to_json(v)))
                return "{" + ", ".join(items) + "}"
            elif type(obj) == "list":
                return "[" + ", ".join([to_json(x) for x in obj]) + "]"
            elif type(obj) == "bool":
                return "true" if obj else "false"
            elif type(obj) == "NoneType":
                return "null"
            elif type(obj) == "int":
                return str(obj)
            else:
                return '"' + str(obj).replace('"', '\\"') + '"'

        payload_str = to_json(payload)
        create_args = build_request("PUT", "/v1/acl/role", payload_str)
        res = ctx.run(create_args)
        if res.rc != 0:
            fail("failed to create role %s: %s" % (name, res.stderr))
        result = res.stdout.strip()
        return {"changed": True, "msg": "created role %s" % name, "data": {"role": result}}

    # Role exists — update if needed
    existing = role

    # Build desired payload without ID for diffing
    desired = {"Name": name}
    if description != None:
        desired["Description"] = description
    if policies != None:
        desired["Policies"] = []
        for p in policies:
            item = {}
            if "id" in p:
                item["ID"] = p["id"]
            if "name" in p:
                item["Name"] = p["name"]
            desired["Policies"].append(item)
    if templated_policies != None:
        desired["TemplatedPolicies"] = []
        for tp in templated_policies:
            item = {"TemplateName": tp["template_name"]}
            if "template_variables" in tp:
                item["TemplateVariables"] = tp["template_variables"]
            desired["TemplatedPolicies"].append(item)
    if service_identities != None:
        desired["ServiceIdentities"] = []
        for si in service_identities:
            item = {"ServiceName": si["service_name"]}
            if "datacenters" in si:
                item["Datacenters"] = si["datacenters"]
            desired["ServiceIdentities"].append(item)
    if node_identities != None:
        desired["NodeIdentities"] = []
        for ni in node_identities:
            item = {"NodeName": ni["node_name"], "Datacenter": ni["datacenter"]}
            desired["NodeIdentities"].append(item)

    # Simple change detection
    changed = False
    if description != None:
        changed = True
    if policies != None:
        changed = True
    if templated_policies != None:
        changed = True
    if service_identities != None:
        changed = True
    if node_identities != None:
        changed = True

    if not changed:
        return {"changed": False, "msg": "role %s already exists" % name}

    # Extract ID from existing role for update
    role_id = None
    lines = existing.split("\n")
    for line in lines:
        if '"ID"' in line and '": "' in line:
            parts = line.split('"ID"')[1].split('": "')
            if len(parts) >= 2:
                role_id = parts[1].split('"')[0]
                break
    if role_id == None:
        fail("could not parse role ID from existing role")

    # Prepare update payload
    update_payload = {"ID": role_id}
    if description != None:
        update_payload["Description"] = description
    if policies != None:
        update_payload["Policies"] = []
        for p in policies:
            item = {}
            if "id" in p:
                item["ID"] = p["id"]
            if "name" in p:
                item["Name"] = p["name"]
            update_payload["Policies"].append(item)
    if templated_policies != None:
        update_payload["TemplatedPolicies"] = []
        for tp in templated_policies:
            item = {"TemplateName": tp["template_name"]}
            if "template_variables" in tp:
                item["TemplateVariables"] = tp["template_variables"]
            update_payload["TemplatedPolicies"].append(item)
    if service_identities != None:
        update_payload["ServiceIdentities"] = []
        for si in service_identities:
            item = {"ServiceName": si["service_name"]}
            if "datacenters" in si:
                item["Datacenters"] = si["datacenters"]
            update_payload["ServiceIdentities"].append(item)
    if node_identities != None:
        update_payload["NodeIdentities"] = []
        for ni in node_identities:
            item = {"NodeName": ni["node_name"], "Datacenter": ni["datacenter"]}
            update_payload["NodeIdentities"].append(item)

    update_payload_str = to_json(update_payload)
    update_args = build_request("PUT", "/v1/acl/role/%s" % role_id, update_payload_str)
    if ctx.check_mode:
        return {"changed": True, "msg": "would update role %s" % name}
    res = ctx.run(update_args)
    if res.rc != 0:
        fail("failed to update role %s: %s" % (name, res.stderr))
    result = res.stdout.strip()
    return {"changed": True, "msg": "updated role %s" % name, "data": {"role": result}}
