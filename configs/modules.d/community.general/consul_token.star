def main(ctx, params):
    state = params.get("state", "present")
    accessor_id = params.get("accessor_id")
    secret_id = params.get("secret_id")
    description = params.get("description")
    expiration_ttl = params.get("expiration_ttl")
    local_flag = params.get("local")
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    ca_path = params.get("ca_path")
    validate_certs = params.get("validate_certs", True)
    token = params.get("token")
    
    base_url = scheme + "://" + host + ":" + str(port) + "/v1/acl/token"
    
    def build_curl_args(endpoint, method="GET", data=None, headers_extra=None):
        args = ["curl", "-s", "-X", method]
        args.extend(["-H", "Content-Type: application/json"])
        if token:
            args.extend(["-H", "X-Consul-Token: " + token])
        if ca_path:
            args.extend(["--cacert", ca_path])
        if not validate_certs:
            args.append("-k")
        if data:
            args.extend(["-d", data])
        args.append(endpoint)
        return args
    
    def json_encode(obj):
        if obj == None:
            return "null"
        if isinstance(obj, bool):
            return "true" if obj else "false"
        if isinstance(obj, int):
            return str(obj)
        if isinstance(obj, str):
            escaped = obj.replace("\\", "\\\\").replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
            return '"' + escaped + '"'
        if isinstance(obj, list):
            items = [json_encode(x) for x in obj]
            return "[" + ", ".join(items) + "]"
        if isinstance(obj, dict):
            pairs = []
            for k in sorted(obj.keys()):
                pairs.append('"' + k + '": ' + json_encode(obj[k]))
            return "{" + ", ".join(pairs) + "}"
        fail("unsupported type for json_encode: " + str(type(obj)))
    
    payload = {}
    if accessor_id:
        payload["AccessorID"] = accessor_id
    if secret_id:
        payload["SecretID"] = secret_id
    if description != None:
        payload["Description"] = description
    if local_flag != None:
        payload["Local"] = local_flag
    if expiration_ttl != None:
        payload["ExpirationTTL"] = expiration_ttl
    
    if "policies" in params:
        policies = params["policies"]
        if policies != None:
            payload_policies = []
            for p in policies:
                policy_entry = {}
                if "id" in p:
                    policy_entry["ID"] = p["id"]
                if "name" in p:
                    policy_entry["Name"] = p["name"]
                if policy_entry:
                    payload_policies.append(policy_entry)
            payload["Policies"] = payload_policies
        else:
            payload["Policies"] = []
    
    if "roles" in params:
        roles = params["roles"]
        if roles != None:
            payload_roles = []
            for r in roles:
                role_entry = {}
                if "id" in r:
                    role_entry["ID"] = r["id"]
                if "name" in r:
                    role_entry["Name"] = r["name"]
                if role_entry:
                    payload_roles.append(role_entry)
            payload["Roles"] = payload_roles
        else:
            payload["Roles"] = []
    
    if "service_identities" in params:
        sids = params["service_identities"]
        if sids != None:
            payload_sids = []
            for sid in sids:
                sid_entry = {}
                if "service_name" in sid:
                    sid_entry["ServiceName"] = sid["service_name"]
                if "datacenters" in sid and sid["datacenters"] != None:
                    sid_entry["Datacenters"] = sid["datacenters"]
                if sid_entry:
                    payload_sids.append(sid_entry)
            payload["ServiceIdentities"] = payload_sids
        else:
            payload["ServiceIdentities"] = []
    
    if "node_identities" in params:
        nids = params["node_identities"]
        if nids != None:
            payload_nids = []
            for nid in nids:
                nid_entry = {}
                if "node_name" in nid:
                    nid_entry["NodeName"] = nid["node_name"]
                if "datacenter" in nid:
                    nid_entry["Datacenter"] = nid["datacenter"]
                if nid_entry:
                    payload_nids.append(nid_entry)
            payload["NodeIdentities"] = payload_nids
        else:
            payload["NodeIdentities"] = []
    
    if "templated_policies" in params and params["templated_policies"]:
        fail("templated_policies is not supported in this Starlark translation")
    
    payload_json = json_encode(payload) if payload else "{}"
    
    if state == "absent":
        if not accessor_id:
            fail("accessor_id is required when state is absent")
        res = ctx.run(build_curl_args(base_url + "/" + accessor_id, method="DELETE"), mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete token with accessor_id " + accessor_id}
        if res.rc != 0:
            fail("failed to delete token: " + res.stderr)
        return {"changed": True, "msg": "deleted token with accessor_id " + accessor_id}
    
    existing_token = None
    if accessor_id:
        res = ctx.run(build_curl_args(base_url + "/" + accessor_id), mutates=False)
        if res.rc == 0:
            existing_token = res.stdout
        elif res.rc != 0 and "ACL not found" not in res.stderr.lower():
            fail("failed to retrieve token: " + res.stderr)
    
    if existing_token:
        res = ctx.run(build_curl_args(base_url, method="PUT", data=payload_json), mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would update token with accessor_id " + accessor_id}
        if res.rc != 0:
            fail("failed to update token: " + res.stderr)
        return {"changed": True, "msg": "updated token with accessor_id " + accessor_id, "data": {"token": res.stdout}}
    else:
        res = ctx.run(build_curl_args(base_url, method="PUT", data=payload_json), mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create token"}
        if res.rc != 0:
            fail("failed to create token: " + res.stderr)
        return {"changed": True, "msg": "created token", "data": {"token": res.stdout}}
