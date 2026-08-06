def main(ctx, params):
    name = params.get("name")
    description = params.get("description")
    parent_id = params.get("parent_id")
    parent = params.get("parent")
    state = params.get("state", "present")
    quotas = params.get("quotas", {})

    if name == None:
        ctx.fail_json(msg="name is required")
    if description == None:
        ctx.fail_json(msg="description is required")
    if parent != None and parent_id != None:
        ctx.fail_json(msg="Cannot specify both parent and parent_id")

    manageiq_conn = params.get("manageiq_connection", {})
    url = manageiq_conn.get("url")
    if url == None or url == "":
        url = ctx.facts().get("manageiq_url", "")
    if url == "":
        ctx.fail_json(msg="ManageIQ URL is required")

    token = manageiq_conn.get("token")
    username = manageiq_conn.get("username")
    password = manageiq_conn.get("password")
    if token == None:
        token = ""
    if username == None:
        username = ""
    if password == None:
        password = ""

    if token == "" and (username == "" or password == ""):
        ctx.fail_json(msg="ManageIQ authentication requires token or username+password")

    validate_certs = manageiq_conn.get("validate_certs")
    if validate_certs == None:
        validate_certs = True

    ca_cert = manageiq_conn.get("ca_cert")
    if ca_cert == None:
        ca_cert = manageiq_conn.get("ca_bundle_path")

    # Helper to call ManageIQ API via ctx.run (curl-based)
    def manageiq_request(method, path, data=None):
        headers = ["-H", "Accept: application/json"]
        if token != "":
            headers += ["-H", "Authorization: Bearer " + token]
        else:
            ctx.fail_json(msg="Basic auth not supported; use token authentication")

        url_full = url.rstrip("/") + "/" + path.lstrip("/")
        argv = ["curl", "-s", "-X", method] + headers
        if data != None:
            argv += ["-d", data]
        argv += [url_full]

        res = ctx.run(argv, mutates=(method != "GET"))
        if res.rc != 0:
            ctx.fail_json(msg="ManageIQ API call failed: " + res.stderr)
        return res.stdout

    # STATE: absent
    if state == "absent":
        # First find tenant by name and parent context
        tenant = None
        parent_tenant = None

        # Build query
        query = "/api/tenants?filter[]=name=" + name
        if parent_id != None:
            res = manageiq_request("GET", "/api/tenants/" + str(parent_id))
            if res == None or res.find('"id"') == -1:
                ctx.fail_json(msg="Parent tenant with id %d not found" % parent_id)
            parent_tenant = {"id": parent_id}
            query += "&filter[]=ancestry=" + str(parent_id)
        elif parent != None:
            pres = manageiq_request("GET", "/api/tenants?filter[]=name=" + parent)
            if pres == None or pres.find(parent) == -1:
                ctx.fail_json(msg="Parent tenant '%s' not found" % parent)
            # Extract parent id from response
            idx = pres.find('"id":')
            if idx == -1:
                ctx.fail_json(msg="Failed to parse parent tenant id")
            # Simplified extraction: skip to number after colon
            idx += 5
            end = idx
            while end < len(pres) and pres[end].isdigit():
                end += 1
            parent_tid = int(pres[idx:end])
            parent_tenant = {"id": parent_tid}
            query += "&filter[]=ancestry=" + str(parent_tid)
        else:
            # Root tenant: ancestry == None or empty
            query += "&filter[]=ancestry=null"

        res = manageiq_request("GET", query)
        # Extract first matching tenant id from response
        if res != None and res.find('"id"') != -1:
            idx = res.find('"id":')
            idx += 5
            end = idx
            while end < len(res) and res[end].isdigit():
                end += 1
            if end > idx:
                tid = int(res[idx:end])
                tenant = {"id": tid}

        if tenant != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete tenant %s" % name}
            manageiq_request("POST", "/api/tenants/" + str(tenant.get("id")), '{"action":"delete"}')
            return {"changed": True, "msg": "tenant %s deleted" % name}
        else:
            if parent_id != None:
                msg = "tenant '%s' with parent_id %d does not exist" % (name, parent_id)
            elif parent != None:
                msg = "tenant '%s' with parent '%s' does not exist" % (name, parent)
            else:
                msg = "tenant '%s' does not exist" % name
            return {"changed": False, "msg": msg}

    # STATE: present
    tenant = None
    parent_tenant = None

    # Find existing tenant
    query = "/api/tenants?filter[]=name=" + name
    if parent_id != None:
        res = manageiq_request("GET", "/api/tenants/" + str(parent_id))
        if res == None or res.find('"id"') == -1:
            ctx.fail_json(msg="Parent tenant with id %d not found" % parent_id)
        parent_tenant = {"id": parent_id}
        query += "&filter[]=ancestry=" + str(parent_id)
    elif parent != None:
        pres = manageiq_request("GET", "/api/tenants?filter[]=name=" + parent)
        if pres == None or pres.find(parent) == -1:
            ctx.fail_json(msg="Parent tenant '%s' not found" % parent)
        # Extract parent id
        idx = pres.find('"id":')
        if idx == -1:
            ctx.fail_json(msg="Failed to parse parent tenant id")
        idx += 5
        end = idx
        while end < len(pres) and pres[end].isdigit():
            end += 1
        parent_tid = int(pres[idx:end])
        parent_tenant = {"id": parent_tid}
        query += "&filter[]=ancestry=" + str(parent_tid)
    else:
        query += "&filter[]=ancestry=null"

    res = manageiq_request("GET", query)
    if res != None and res.find('"id"') != -1:
        idx = res.find('"id":')
        idx += 5
        end = idx
        while end < len(res) and res[end].isdigit():
            end += 1
        if end > idx:
            tid = int(res[idx:end])
            tenant = {"id": tid}

    # If tenant exists, check if update needed
    if tenant != None:
        # Check current values
        details = manageiq_request("GET", "/api/tenants/" + str(tenant.get("id")))
        name_match = details != None and details.find('"name":"%s"' % name) != -1
        desc_match = details != None and details.find('"description":"%s"' % description) != -1

        if name_match and desc_match and len(quotas) == 0:
            return {"changed": False, "msg": "tenant already exists", "tenant": tenant}

        if ctx.check_mode:
            return {"changed": True, "msg": "would update tenant %s" % name}

        manageiq_request("POST", "/api/tenants/" + str(tenant.get("id")), '{"action":"edit","resource":{"name":"%s","description":"%s","use_config_for_attributes":false}}' % (name, description))

        # Reload with quotas
        details = manageiq_request("GET", "/api/tenants/" + str(tenant.get("id")) + "?expand=resources&attributes=[tenant_quotas]")

        # Handle quotas
        if len(quotas) > 0:
            for qk, qv in quotas.items():
                if qv != None:
                    val = int(qv)
                    if qk in ("storage_allocated", "mem_allocated"):
                        val = val * 1024 * 1024 * 1024
                    manageiq_request("POST", "/api/tenants/" + str(tenant.get("id")) + "/quotas", '{"action":"create","resource":{"name":"%s","value":%d}}' % (qk, val))
                else:
                    # Delete quota
                    qres = manageiq_request("GET", "/api/tenants/" + str(tenant.get("id")) + "/quotas?filter[]=name=" + qk)
                    if qres != None and qres.find('"id":') != -1:
                        idx = qres.find('"id":')
                        idx += 5
                        end = idx
                        while end < len(qres) and qres[end].isdigit():
                            end += 1
                        if end > idx:
                            qid = int(qres[idx:end])
                            manageiq_request("POST", "/api/tenants/" + str(tenant.get("id")) + "/quotas/" + str(qid), '{"action":"delete"}')
            # Reload again
            details = manageiq_request("GET", "/api/tenants/" + str(tenant.get("id")) + "?expand=resources&attributes=[tenant_quotas]")

        return {"changed": True, "msg": "tenant updated", "tenant": tenant}
    else:
        # Create tenant
        if parent_tenant == None:
            parent_id_int = None
        else:
            parent_id_int = int(parent_tenant.get("id"))
        if ctx.check_mode:
            return {"changed": True, "msg": "would create tenant %s" % name}

        parent_json = "null"
        if parent_id_int != None:
            parent_json = str(parent_id_int)

        manageiq_request("POST", "/api/tenants", '{"action":"create","resource":{"name":"%s","description":"%s","parent":{"id":%s}}}' % (name, description, parent_json))

        # Get created tenant
        # Query by name again and find new id
        res = manageiq_request("GET", "/api/tenants?filter[]=name=" + name)
        idx = res.find('"id":')
        if idx == -1:
            ctx.fail_json(msg="Failed to get created tenant id")
        idx += 5
        end = idx
        while end < len(res) and res[end].isdigit():
            end += 1
        if end <= idx:
            ctx.fail_json(msg="Failed to extract tenant id")
        tenant_id = int(res[idx:end])
        tenant = {"id": tenant_id}

        details = manageiq_request("GET", "/api/tenants/" + str(tenant_id) + "?expand=resources&attributes=[tenant_quotas]")

        # Process quotas
        if len(quotas) > 0:
            for qk, qv in quotas.items():
                if qv != None:
                    val = int(qv)
                    if qk in ("storage_allocated", "mem_allocated"):
                        val = val * 1024 * 1024 * 1024
                    manageiq_request("POST", "/api/tenants/" + str(tenant_id) + "/quotas", '{"action":"create","resource":{"name":"%s","value":%d}}' % (qk, val))
                else:
                    qres = manageiq_request("GET", "/api/tenants/" + str(tenant_id) + "/quotas?filter[]=name=" + qk)
                    if qres != None and qres.find('"id":') != -1:
                        idx = qres.find('"id":')
                        idx += 5
                        end = idx
                        while end < len(qres) and qres[end].isdigit():
                            end += 1
                        if end > idx:
                            qid = int(qres[idx:end])
                            manageiq_request("POST", "/api/tenants/" + str(tenant_id) + "/quotas/" + str(qid), '{"action":"delete"}')
            details = manageiq_request("GET", "/api/tenants/" + str(tenant_id) + "?expand=resources&attributes=[tenant_quotas]")

        return {"changed": True, "msg": "tenant created", "tenant": tenant}
