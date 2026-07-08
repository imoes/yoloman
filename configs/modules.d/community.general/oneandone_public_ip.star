def main(ctx, params):
    auth_token = params.get("auth_token")
    api_url = params.get("api_url")
    public_ip_id = params.get("public_ip_id")
    reverse_dns = params.get("reverse_dns")
    datacenter = params.get("datacenter", "US")
    ip_type = params.get("type", "IPV4")
    state = params.get("state", "present")
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 600)
    wait_interval = params.get("wait_interval", 5)

    if auth_token == None:
        fail("auth_token parameter is required.")

    if datacenter not in ["US", "ES", "DE", "GB"]:
        fail("datacenter must be one of: US, ES, DE, GB")
    if ip_type not in ["IPV4", "IPV6"]:
        fail("type must be one of: IPV4, IPV6")
    if state not in ["present", "absent", "update"]:
        fail("state must be one of: present, absent, update")

    if state in ["absent", "update"] and public_ip_id == None:
        fail("public_ip_id parameter is required when state is " + state + ".")

    base_url = api_url if api_url != None else "https://api.1andone.com/v1"

    def http_get(path):
        exe = "curl"
        res = ctx.run([exe, "-sS", "-X", "GET", base_url + path, "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token], mutates=False)
        if res.rc != 0:
            fail("GET " + path + " failed: " + res.stderr)
        return res.stdout

    def http_post(path, payload):
        exe = "curl"
        res = ctx.run([exe, "-sS", "-X", "POST", base_url + path, "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, "-d", payload], mutates=True)
        if res.rc != 0:
            fail("POST " + path + " failed: " + res.stderr)
        return res.stdout

    def http_patch(path, payload):
        exe = "curl"
        res = ctx.run([exe, "-sS", "-X", "PATCH", base_url + path, "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, "-d", payload], mutates=True)
        if res.rc != 0:
            fail("PATCH " + path + " failed: " + res.stderr)
        return res.stdout

    def http_delete(path):
        exe = "curl"
        res = ctx.run([exe, "-sS", "-X", "DELETE", base_url + path, "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token], mutates=True)
        if res.rc != 0:
            fail("DELETE " + path + " failed: " + res.stderr)
        return ""

    def extract_str_field(json_str, field):
        start = json_str.find('"' + field + '":')
        if start == -1:
            return ""
        start = start + len(field) + 4
        end = json_str.find('"', start)
        if end == -1:
            return ""
        return json_str[start:end]

    def get_public_ip(ip_id):
        resp = http_get("/public_ips/" + ip_id)
        ip_id_out = extract_str_field(resp, "id")
        ip_addr = extract_str_field(resp, "ip")
        if ip_id_out == "" or ip_addr == "":
            return None
        return {"id": ip_id_out, "ip": ip_addr}

    def find_ip_by_reverse_dns(rd):
        resp = http_get("/public_ips")
        parts = resp.split('"reverse_dns":')
        for part in parts[1:]:
            if part.startswith("null"):
                continue
            if part.startswith('""'):
                end_quote = part.find('"', 2)
                if end_quote == 1:
                    continue
            end = part.find('",')
            if end == -1:
                continue
            rd_candidate = part[2:end]
            if rd_candidate != rd:
                continue
            rest = part[end:]
            ip_addr = extract_str_field(rest, "ip")
            ip_id_out = extract_str_field(rest, "id")
            if ip_id_out != "" and ip_addr != "":
                return {"id": ip_id_out, "ip": ip_addr}
        return None

    def wait_for_ip(ip_id, timeout, interval):
        max_attempts = int(timeout / interval)
        for _ in range(max_attempts):
            ip = get_public_ip(ip_id)
            if ip != None:
                return ip
        return get_public_ip(ip_id)

    if state == "absent":
        if ctx.check_mode:
            ip = get_public_ip(public_ip_id)
            if ip != None:
                return {"changed": True, "msg": "would delete public IP " + public_ip_id}
            return {"changed": False, "msg": "public IP " + public_ip_id + " not found"}
        ip = get_public_ip(public_ip_id)
        if ip == None:
            return {"changed": False, "msg": "public IP " + public_ip_id + " not found"}
        http_delete("/public_ips/" + public_ip_id)
        return {"changed": True, "msg": "deleted public IP " + public_ip_id, "data": {"id": ip["id"], "ip": ip["ip"]}}

    elif state == "update":
        ip = get_public_ip(public_ip_id)
        if ip == None:
            if ctx.check_mode:
                return {"changed": False, "msg": "public IP " + public_ip_id + " not found"}
            fail("public IP " + public_ip_id + " not found.")
        if reverse_dns == None:
            return {"changed": False, "msg": "no update requested", "data": ip}
        payload = '{"reverse_dns": "' + reverse_dns + '"}'
        if ctx.check_mode:
            return {"changed": True, "msg": "would update reverse_dns of IP " + public_ip_id}
        http_patch("/public_ips/" + public_ip_id, payload)
        updated = get_public_ip(public_ip_id)
        return {"changed": True, "msg": "updated reverse_dns of IP " + public_ip_id, "data": updated}

    elif state == "present":
        if reverse_dns != None:
            existing = find_ip_by_reverse_dns(reverse_dns)
            if existing != None:
                return {"changed": False, "msg": "IP with reverse_dns " + reverse_dns + " already exists", "data": existing}

        datacenter_id = datacenter
        payload = '{"ip_type": "' + ip_type + '", "datacenter_id": "' + datacenter_id + '"'
        if reverse_dns != None:
            payload += ', "reverse_dns": "' + reverse_dns + '"'
        payload += '}'

        if ctx.check_mode:
            return {"changed": True, "msg": "would create public IP in " + datacenter_id}

        resp = http_post("/public_ips", payload)

        ip_id_out = extract_str_field(resp, "id")
        ip_addr = extract_str_field(resp, "ip")

        result_ip = {"id": ip_id_out, "ip": ip_addr}
        if wait and not ctx.check_mode:
            result_ip = wait_for_ip(ip_id_out, wait_timeout, wait_interval)
            if result_ip == None:
                fail("IP " + ip_id_out + " not found after creation.")

        return {"changed": True, "msg": "created public IP " + ip_id_out, "data": result_ip}

    fail("unsupported state: " + state)
