def main(ctx, params):
    # Required params
    name = params["name"]
    state = params.get("state", "present")
    provider_type = params.get("type")
    zone_name = params.get("zone", "default")

    # Optional provider parameters
    provider_region = params.get("provider_region")
    host_default_vnc_port_start = params.get("host_default_vnc_port_start")
    host_default_vnc_port_end = params.get("host_default_vnc_port_end")
    subscription = params.get("subscription")
    project = params.get("project")
    uid_ems = params.get("azure_tenant_id")
    tenant_mapping_enabled = params.get("tenant_mapping_enabled", False)
    api_version = params.get("api_version")

    # Supported providers mapping
    supported = {
        "Openshift": "ManageIQ::Providers::Openshift::ContainerManager",
        "Amazon": "ManageIQ::Providers::Amazon::CloudManager",
        "oVirt": "ManageIQ::Providers::Redhat::InfraManager",
        "VMware": "ManageIQ::Providers::Vmware::InfraManager",
        "Azure": "ManageIQ::Providers::Azure::CloudManager",
        "Director": "ManageIQ::Providers::Openstack::InfraManager",
        "OpenStack": "ManageIQ::Providers::Openstack::CloudManager",
        "GCE": "ManageIQ::Providers::Google::CloudManager",
    }

    # ManageIQ connection setup
    conn = params.get("manageiq_connection", {})
    url = conn.get("url")
    username = conn.get("username")
    password = conn.get("password")
    token = conn.get("token")
    ca_cert = conn.get("ca_cert")
    validate_certs = conn.get("validate_certs", True)

    if url == None:
        fail("manageiq_connection.url is required")

    # Build auth headers
    auth_header = ""
    if token != None:
        auth_header = "Authorization: Bearer " + token
    elif username != None and password != None:
        # Simple base64 implementation
        base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        plain = username + ":" + password
        encoded = ""
        i = 0
        while i < len(plain):
            c1 = ord(plain[i])
            i += 1
            c2 = ord(plain[i]) if i < len(plain) else 0
            i += 1
            c3 = ord(plain[i]) if i < len(plain) else 0
            i += 1
            
            encoded += base64_chars[c1 >> 2]
            encoded += base64_chars[((c1 & 3) << 4) | (c2 >> 4)]
            if i-2 < len(plain):
                encoded += base64_chars[((c2 & 15) << 2) | (c3 >> 6)]
            if i-1 < len(plain):
                encoded += base64_chars[c3 & 63]
        
        padding = (4 - len(encoded) % 4) % 4
        encoded = encoded + ("=" * padding)
        
        auth_header = "Authorization: Basic " + encoded
    else:
        fail("manageiq_connection: provide either token, or username and password")

    # Helper: find provider by name
    res = ctx.run(["curl", "-sS", "-X", "GET",
        "-H", "Content-Type: application/json",
        "-H", auth_header,
        "-k" if not validate_certs else "",
        url + "/api/providers?expand=resources&filter[name]=" + name],
        mutates=False)
    if res.rc != 0:
        fail("failed to query providers: " + res.stderr)
    data = res.stdout
    providers = []
    idx = data.find('"resources":[')
    if idx != -1:
        rest = data[idx + len('"resources":['):]
        bracket_count = 0
        start = -1
        for i in range(len(rest)):
            if rest[i] == '[':
                bracket_count += 1
            elif rest[i] == ']':
                bracket_count -= 1
                if bracket_count == 0:
                    arr_str = rest[:i+1]
                    # Split objects manually
                    items = arr_str.split('{')
                    for item in items:
                        if item.strip() == '':
                            continue
                        obj = '{' + item.strip()
                        if obj.endswith(','):
                            obj = obj[:-1]
                        # Extract id and name
                        id_idx = obj.find('"id":')
                        name_idx = obj.find('"name":')
                        prov_id = None
                        prov_name = None
                        if id_idx != -1:
                            id_str = obj[id_idx+len('"id":'):].strip()
                            end = id_str.find(',')
                            if end == -1:
                                end = id_str.find('}')
                            if end != -1:
                                prov_id = int(id_str[:end].strip())
                        if name_idx != -1:
                            name_str = obj[name_idx+len('"name":'):].strip()
                            end = name_str.find(',')
                            if end == -1:
                                end = name_str.find('}')
                            if end != -1:
                                prov_name = name_str[1:end-1].strip()
                        if prov_id != None and prov_name != None:
                            providers.append({"id": prov_id, "name": prov_name})
                    break
    if len(providers) == 0:
        providers = []

    provider = None
    for p in providers:
        if p["name"] == name:
            provider = p
            break

    # Zone lookup
    res = ctx.run(["curl", "-sS", "-X", "GET",
        "-H", "Content-Type: application/json",
        "-H", auth_header,
        "-k" if not validate_certs else "",
        url + "/api/zones?filter[name]=" + zone_name],
        mutates=False)
    if res.rc != 0:
        fail("failed to query zones: " + res.stderr)
    zone_id = None
    data = res.stdout
    idx = data.find('"resources":[')
    if idx != -1:
        rest = data[idx + len('"resources":['):]
        bracket_count = 0
        for i in range(len(rest)):
            if rest[i] == '[':
                bracket_count += 1
            elif rest[i] == ']':
                bracket_count -= 1
                if bracket_count == 0:
                    arr_str = rest[:i+1]
                    items = arr_str.split('{')
                    for item in items:
                        if item.strip() == '':
                            continue
                        obj = '{' + item.strip()
                        if obj.endswith(','):
                            obj = obj[:-1]
                        id_idx = obj.find('"id":')
                        name_idx = obj.find('"name":')
                        z_id = None
                        z_name = None
                        if id_idx != -1:
                            id_str = obj[id_idx+len('"id":'):].strip()
                            end = id_str.find(',')
                            if end == -1:
                                end = id_str.find('}')
                            if end != -1:
                                z_id = int(id_str[:end].strip())
                        if name_idx != -1:
                            name_str = obj[name_idx+len('"name":'):].strip()
                            end = name_str.find(',')
                            if end == -1:
                                end = name_str.find('}')
                            if end != -1:
                                z_name = name_str[1:end-1].strip()
                        if z_name == zone_name and z_id != None:
                            zone_id = z_id
                            break
                    break

    if zone_id == None:
        fail("zone %s does not exist in ManageIQ" % zone_name)

    # State handling
    if state == "absent":
        if provider == None:
            return {"changed": False, "msg": "provider %s does not exist" % name}
        # Delete
        res = ctx.run(["curl", "-sS", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", auth_header,
            "-k" if not validate_certs else "",
            "-d", '{"action":"delete"}',
            url + "/api/providers/" + str(provider["id"])],
            mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete provider " + name}
        if res.rc != 0:
            fail("failed to delete provider %s: %s" % (name, res.stderr))
        msg = "deleted"
        return {"changed": True, "msg": msg}

    if state == "refresh":
        if provider == None:
            return {"changed": False, "msg": "provider %s does not exist" % name}
        res = ctx.run(["curl", "-sS", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", auth_header,
            "-k" if not validate_certs else "",
            "-d", '{"action":"refresh"}',
            url + "/api/providers/" + str(provider["id"])],
            mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would refresh provider " + name}
        if res.rc != 0:
            fail("failed to refresh provider %s: %s" % (name, res.stderr))
        msg = "refreshing"
        return {"changed": True, "msg": "refreshing provider " + name}

    # State == "present"
    if provider_type == None:
        if provider != None:
            fail("provider type is required when creating a new provider")
        else:
            fail("provider type is required")
    if not provider_type in supported:
        fail("provider type %s is not supported" % provider_type)

    # Build endpoints
    def build_endpoint(endpoint_key, default_role):
        ep = params.get(endpoint_key, {})
        if type(ep) != "dict" or len(ep) == 0:
            return None
        # Build endpoint dict
        endpoint = {
            "role": ep.get("role") or default_role,
            "hostname": ep.get("hostname"),
            "port": ep.get("port"),
            "verify_ssl": [0, 1][bool(ep.get("validate_certs", True))],
            "security_protocol": ep.get("security_protocol"),
            "certificate_authority": ep.get("certificate_authority"),
            "path": ep.get("path"),
        }
        role = endpoint["role"]
        authtype = role
        if role == "default":
            authtype = "default"
        auth = {
            "authtype": authtype,
            "userid": ep.get("userid"),
            "password": ep.get("password"),
            "auth_key": ep.get("auth_key"),
        }
        return {"endpoint": endpoint, "authentication": auth}

    # Provider endpoints list
    connection_configurations = []
    provider_ep = params.get("provider")
    if provider_ep == None:
        fail("provider endpoint is required when state is present")
    default_auth_key = provider_ep.get("auth_key")
    # Build provider endpoint
    p_ep = build_endpoint("provider", "default")
    if p_ep != None:
        # Override auth_key if provider has it
        if p_ep["authentication"].get("auth_key") == None:
            p_ep["authentication"]["auth_key"] = default_auth_key
        connection_configurations.append(p_ep)
    # Metrics
    m_ep = build_endpoint("metrics", "prometheus")
    if m_ep != None:
        if m_ep["authentication"].get("auth_key") == None:
            m_ep["authentication"]["auth_key"] = default_auth_key
        connection_configurations.append(m_ep)
    # Alerts
    a_ep = build_endpoint("alerts", "prometheus_alerts")
    if a_ep != None:
        if a_ep["authentication"].get("auth_key") == None:
            a_ep["authentication"]["auth_key"] = default_auth_key
        connection_configurations.append(a_ep)
    # SSH Keypair
    s_ep = build_endpoint("ssh_keypair", "ssh_keypair")
    if s_ep != None:
        if s_ep["authentication"].get("auth_key") == None:
            s_ep["authentication"]["auth_key"] = default_auth_key
        connection_configurations.append(s_ep)

    # Clean nulls
    def clean_nulls(obj):
        if type(obj) == "list":
            return [clean_nulls(x) for x in obj if x != None]
        elif type(obj) == "dict":
            new = {}
            for k in obj:
                v = obj[k]
                if v != None:
                    new[k] = clean_nulls(v)
            return new
        else:
            return obj

    connection_configurations = clean_nulls(connection_configurations)

    # Build resource
    resource = {
        "name": name,
        "zone": {"id": zone_id},
        "provider_region": provider_region,
        "host_default_vnc_port_start": host_default_vnc_port_start,
        "host_default_vnc_port_end": host_default_vnc_port_end,
        "subscription": subscription,
        "project": project,
        "uid_ems": uid_ems,
        "tenant_mapping_enabled": bool(tenant_mapping_enabled),
        "api_version": api_version,
        "connection_configurations": connection_configurations,
    }
    resource = clean_nulls(resource)

    if provider != None:
        # Edit existing
        res = ctx.run(["curl", "-sS", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", auth_header,
            "-k" if not validate_certs else "",
            "-d", '{"action":"edit","resource":%s}' % str(resource).replace("'", '"'),
            url + "/api/providers/" + str(provider["id"])],
            mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would update provider " + name}
        if res.rc != 0:
            fail("failed to update provider %s: %s" % (name, res.stderr))
        msg = "updated"
        return {"changed": True, "msg": msg}
    else:
        # Create new
        resource["type"] = supported[provider_type]
        res = ctx.run(["curl", "-sS", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", auth_header,
            "-k" if not validate_certs else "",
            "-d", str(resource).replace("'", '"'),
            url + "/api/providers"],
            mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create provider " + name}
        if res.rc != 0:
            fail("failed to create provider %s: %s" % (name, res.stderr))
        msg = "created"
        return {"changed": True, "msg": msg}
