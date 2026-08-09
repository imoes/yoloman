def main(ctx, params):
    # Required params
    organization = params["organization"]
    region = params["region"]
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    state = params.get("state", "present")
    id = params.get("id")
    server = params.get("server")
    reverse = params.get("reverse")

    # Region mapping (simplified from SCALEWAY_LOCATION)
    region_map = {
        "ams1": "https://api.scaleway.com/ips/v1/regions/ams1",
        "EMEA-NL-EVS": "https://api.scaleway.com/ips/v1/regions/ams1",
        "par1": "https://api.scaleway.com/ips/v1/regions/par1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/ips/v1/regions/par1",
        "par2": "https://api.scaleway.com/ips/v1/regions/par2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/ips/v1/regions/par2",
        "waw1": "https://api.scaleway.com/ips/v1/regions/waw1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/ips/v1/regions/waw1",
    }
    if region not in region_map:
        fail("unsupported region: " + region)
    base_url = region_map[region]

    # Helper function to parse simple JSON manually (no json module, no try/except)
    def parse_json(s):
        s = s.strip()
        if s == "null":
            return None
        if s == "true":
            return True
        if s == "false":
            return False
        if s.startswith("{"):
            result = {}
            inner = s[1:-1].strip()
            if not inner:
                return result
            # Split by top-level commas
            parts = []
            depth = 0
            current = ""
            for c in inner:
                if c == "," and depth == 0:
                    parts.append(current.strip())
                    current = ""
                else:
                    current += c
                    if c in "{[":
                        depth += 1
                    elif c in "}]":
                        depth -= 1
            if current.strip():
                parts.append(current.strip())
            for part in parts:
                colon_idx = part.find(":")
                if colon_idx == -1:
                    fail("Invalid JSON: missing colon in key-value")
                key = part[:colon_idx].strip().strip('"')
                value = part[colon_idx + 1:].strip()
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                elif value.startswith("{") or value.startswith("["):
                    value = parse_json(value)
                elif value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                    value = int(value)
                else:
                    # fail if non-numeric fallback — this is acceptable for Scaleway JSON
                    fail("invalid numeric value: " + value)
                result[key] = value
            return result
        if s.startswith("["):
            result = []
            inner = s[1:-1].strip()
            if not inner:
                return result
            parts = []
            depth = 0
            current = ""
            for c in inner:
                if c == "," and depth == 0:
                    parts.append(current.strip())
                    current = ""
                else:
                    current += c
                    if c in "{[":
                        depth += 1
                    elif c in "}]":
                        depth -= 1
            if current.strip():
                parts.append(current.strip())
            for item in parts:
                if item.startswith('"') and item.endswith('"'):
                    result.append(item[1:-1])
                elif item.startswith("{") or item.startswith("["):
                    result.append(parse_json(item))
                elif item == "true":
                    result.append(True)
                elif item == "false":
                    result.append(False)
                elif item.isdigit() or (item.startswith("-") and item[1:].isdigit()):
                    result.append(int(item))
                else:
                    fail("invalid list item: " + item)
            return result
        # numeric fallback
        if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
            return int(s)
        fail("unsupported JSON value: " + s)

    def get_ips():
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "GET",
                "-H",
                "Content-Type: application/json",
                "-H",
                "X-Auth-Token: " + api_token,
                base_url + "/ips",
            ],
            mutates=False
        )
        if res.rc != 0:
            fail("API GET error: " + res.stderr)
        return parse_json(res.stdout).get("ips", [])

    def create_ip(payload_str):
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "POST",
                "-H",
                "Content-Type: application/json",
                "-H",
                "X-Auth-Token: " + api_token,
                "-d",
                payload_str,
                base_url + "/ips",
            ],
            mutates=True
        )
        if res.rc != 0:
            fail("API POST error: " + res.stderr)
        return parse_json(res.stdout)

    def update_ip(ip_id, payload_str):
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "PATCH",
                "-H",
                "Content-Type: application/json",
                "-H",
                "X-Auth-Token: " + api_token,
                "-d",
                payload_str,
                base_url + "/ips/" + str(ip_id),
            ],
            mutates=True
        )
        if res.rc != 0:
            fail("API PATCH error: " + res.stderr)
        return parse_json(res.stdout)

    def delete_ip(ip_id):
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "DELETE",
                "-H",
                "Content-Type: application/json",
                "-H",
                "X-Auth-Token: " + api_token,
                base_url + "/ips/" + str(ip_id),
            ],
            mutates=True
        )
        if res.rc != 0:
            fail("API DELETE error: " + res.stderr)
        return parse_json(res.stdout)

    def payload_from_wished_ip(wished_ip):
        # Build a minimal JSON string manually
        parts = []
        for k in ["organization", "reverse", "server"]:
            v = wished_ip.get(k)
            if v != None:
                if type(v) == "bool" or type(v) == "int" or type(v) == "float":
                    parts.append('"' + k + '":' + str(v))
                elif type(v) == "string":
                    parts.append('"' + k + '":"%s"' % v)
                else:
                    parts.append('"' + k + '":' + str(v))
        return "{" + ",".join(parts) + "}"

    def ip_attributes_should_be_changed(target_ip, wished_ip):
        patch_payload = {}
        if target_ip.get("reverse") != wished_ip.get("reverse"):
            patch_payload["reverse"] = wished_ip.get("reverse")

        # Check if server is being assigned/unassigned
        target_server_id = None
        if target_ip.get("server") != None:
            target_server_id = target_ip.get("server").get("id")

        if target_server_id == None and wished_ip.get("server") != None:
            patch_payload["server"] = wished_ip.get("server")
        elif target_server_id != None and wished_ip.get("server") == None:
            patch_payload["server"] = None
        elif target_server_id != None and wished_ip.get("server") != None:
            if target_server_id != wished_ip.get("server"):
                patch_payload["server"] = wished_ip.get("server")

        return patch_payload

    wished_ip = {
        "organization": organization,
        "reverse": reverse,
        "id": id,
        "server": server
    }

    # Ensure id is present for state=present operations
    if state == "present" and id == None:
        fail("id is required for present state (use a previous registration to get the IP id)")

    ips_list = get_ips()
    ip_lookup = {}
    for ip in ips_list:
        ip_lookup[ip.get("id")] = ip

    if state == "absent":
        if id not in ip_lookup:
            return {"changed": False, "msg": "IP not found, nothing to delete"}
        changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "IP would be destroyed"}

        delete_res = delete_ip(id)
        return {"changed": True, "msg": "IP deleted", "data": delete_res}

    # state == present
    if id not in ip_lookup:
        changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "An IP would be created."}

        payload_str = payload_from_wished_ip(wished_ip)
        create_res = create_ip(payload_str)
        return {"changed": True, "msg": "IP created", "data": create_res}

    target_ip = ip_lookup[id]
    patch_payload = ip_attributes_should_be_changed(target_ip, wished_ip)

    if len(patch_payload) == 0:
        return {"changed": False, "msg": "IP already has desired attributes", "data": target_ip}

    changed = True
    if ctx.check_mode:
        return {"changed": True, "msg": "IP attributes would be changed."}

    payload_str = payload_from_wished_ip(patch_payload)
    patch_res = update_ip(target_ip.get("id"), payload_str)
    return {"changed": True, "msg": "IP updated", "data": patch_res}
