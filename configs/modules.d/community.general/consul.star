def main(ctx, params):
    # Extract parameters
    state = params.get("state", "present")
    service_name = params.get("service_name")
    service_id = params.get("service_id")
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    validate_certs = params.get("validate_certs", True)
    check_id = params.get("check_id")
    check_name = params.get("check_name")
    script = params.get("script")
    interval = params.get("interval")
    ttl = params.get("ttl")
    tcp = params.get("tcp")
    http = params.get("http")
    timeout = params.get("timeout")
    service_port = params.get("service_port")
    service_address = params.get("service_address")
    tags = params.get("tags")
    token = params.get("token")

    # Validate mutually exclusive check types
    check_types = [script, ttl, tcp, http]
    active_check_types = [t for t in check_types if t != None]
    if len(active_check_types) > 1:
        fail("Parameters script, ttl, tcp, and http are mutually exclusive")

    # Validate required interval for script/http/tcp
    if script or http or tcp:
        if not interval:
            fail("interval is required when using script, http, or tcp")

    # Validate state=absent constraints
    if state == "absent":
        if any(active_check_types):
            fail("Parameters script, ttl, tcp, http, interval are not allowed with state=absent")
        if not (service_id or service_name or check_id or check_name):
            fail("At least one of service_id, service_name, check_id, or check_name is required for state=absent")

    # Validate service registration
    if state == "present":
        if not service_name:
            fail("service_name is required for state=present")

    # Construct base URL
    scheme_str = scheme
    if not scheme_str.endswith("://"):
        scheme_str += "://"
    base_url = scheme_str + host + ":" + str(port)

    # Build headers
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Consul-Token"] = token

    # Determine operation
    if state == "absent":
        # Deregister service or check
        if service_id or service_name:
            sid = service_id if service_id else service_name
            url = base_url + "/v1/agent/service/deregister/" + sid
            res = ctx.run(["curl", "-s", "-X", "PUT", url], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would deregister service " + sid}
            if res.rc != 0:
                fail("Failed to deregister service " + sid + ": " + res.stderr)
            # Check if service still exists (idempotent)
            services = ctx.run(["curl", "-s", base_url + "/v1/agent/services"], mutates=False)
            if services.rc != 0:
                fail("Failed to list services: " + services.stderr)
            services_data = services.stdout
            # Simple string search for service ID (consul JSON format)
            # Since no JSON parsing, use basic search
            if ' "' + sid + '":' in services_data or '"ID": "' + sid + '"' in services_data:
                fail("Service deregistration failed: still present")
            return {"changed": True, "msg": "deregistered service " + sid}
        else:
            # Deregister check
            cid = check_id if check_id else check_name
            if not cid:
                fail("check_id or check_name required for check deregistration")
            url = base_url + "/v1/agent/check/deregister/" + cid
            res = ctx.run(["curl", "-s", "-X", "PUT", url], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would deregister check " + cid}
            if res.rc != 0:
                fail("Failed to deregister check " + cid + ": " + res.stderr)
            # Verify removal
            checks = ctx.run(["curl", "-s", base_url + "/v1/agent/checks"], mutates=False)
            if checks.rc != 0:
                fail("Failed to list checks: " + checks.stderr)
            checks_data = checks.stdout
            if ' "' + cid + '":' in checks_data or '"CheckID": "' + cid + '"' in checks_data:
                fail("Check deregistration failed: still present")
            return {"changed": True, "msg": "deregistered check " + cid}

    # State == present: register service/check
    # Build request payload (as string since no JSON module)
    req_body = "{"
    req_parts = []

    # Service part
    if service_name:
        req_parts.append('"Name": "' + service_name.replace('"', '\\"') + '"')
        if service_id:
            req_parts.append('"ID": "' + service_id.replace('"', '\\"') + '"')
        else:
            req_parts.append('"ID": "' + service_name.replace('"', '\\"') + '"')
        if service_port != None:
            req_parts.append('"Port": ' + str(int(service_port)))
        if service_address:
            req_parts.append('"Address": "' + service_address.replace('"', '\\"') + '"')
        if tags:
            tags_str = "["
            for i, tag in enumerate(tags):
                if i > 0:
                    tags_str += ","
                tags_str += '"' + tag.replace('"', '\\"') + '"'
            tags_str += "]"
            req_parts.append('"Tags": ' + tags_str)

    # Check part
    check_parts = []
    if script:
        check_parts.append('"Script": "' + script.replace('"', '\\"') + '"')
        check_parts.append('"Interval": "' + interval + '"')
    elif ttl:
        check_parts.append('"TTL": "' + ttl + '"')
    elif tcp:
        # Parse tcp "host:port"
        if ":" not in tcp:
            fail("tcp check must be in host:port format")
        parts = tcp.rsplit(":", 1)
        host_part = parts[0]
        port_part = parts[1]
        check_parts.append('"TCP": "' + host_part + ":" + port_part + '"')
        check_parts.append('"Interval": "' + interval + '"')
    elif http:
        check_parts.append('"HTTP": "' + http.replace('"', '\\"') + '"')
        check_parts.append('"Interval": "' + interval + '"')
        if timeout:
            check_parts.append('"Timeout": "' + timeout + '"')

    if check_parts:
        req_parts.append('"Check": {' + ",".join(check_parts) + '}')

    req_body += ",".join(req_parts) + "}"

    # Determine endpoint
    url = base_url + "/v1/agent/service/register"
    if not service_name:
        # Node-level check (no service) - not officially supported by consul API directly
        fail("Node-level checks require service registration with service_name (Consul API limitation)")

    # Execute registration
    res = ctx.run(["curl", "-s", "-X", "PUT", "-d", req_body, "-H", "Content-Type: application/json", url], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would register service"}
    if res.rc != 0:
        fail("Failed to register service: " + res.stderr)

    return {"changed": True, "msg": "service registered"}
