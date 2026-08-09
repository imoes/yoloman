def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    hostname = params.get("hostname")
    address = params.get("address", "0.0.0.0")
    address6 = params.get("address6", "::")
    comment = params.get("comment", "")
    interface = params.get("interface", "")
    resolved = params.get("resolved", False)
    resolved6 = params.get("resolved6", False)
    timeout = params.get("timeout", 0)
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)

    # Validate required fields
    if state == "present" and hostname == None:
        fail("hostname is required when state is present")

    # Build UTM endpoint URL
    protocol = "http" if utm_protocol == "http" else "https"
    base_url = "%s://%s:%s" % (protocol, utm_host, str(utm_port))
    endpoint = "/network/dns_host"

    # Function to get existing entry by name
    def get_entry_by_name():
        res = ctx.run([
            "curl", "-s", "-k",
            "-H", "X-Token: " + utm_token,
            "-H", "Content-Type: application/json",
            base_url + endpoint
        ])
        if res.rc != 0:
            fail("failed to list DNS hosts: " + res.stderr)

        lines = res.stdout.strip().split("\n")
        items_str = res.stdout.strip()
        if items_str == "" or items_str == "[]":
            return None

        # Split into object strings by },{ pattern
        parts = []
        depth = 0
        current = ""
        for char in items_str:
            if char == "{":
                depth = depth + 1
                current = current + char
            elif char == "}":
                depth = depth - 1
                current = current + char
                if depth == 0:
                    parts.append(current.strip())
                    current = ""
            elif depth > 0:
                current = current + char

        for part in parts:
            if part.find('"name"') != -1:
                name_start = part.find('"name"')
                if name_start != -1:
                    colon_idx = part.find(":", name_start)
                    if colon_idx != -1:
                        quote1 = part.find('"', colon_idx + 1)
                        if quote1 != -1:
                            quote2 = part.find('"', quote1 + 1)
                            if quote2 != -1:
                                extracted_name = part[quote1 + 1:quote2]
                                if extracted_name == name:
                                    return part
        return None

    # Function to parse field value from JSON-like string
    def extract_value(json_str, key):
        idx = json_str.find('"' + key + '"')
        if idx == -1:
            return None
        colon_idx = json_str.find(":", idx)
        if colon_idx == -1:
            return None
        start = colon_idx + 1
        while start < len(json_str) and (json_str[start] == " " or json_str[start] == "\t"):
            start = start + 1

        if json_str[start:].startswith("null"):
            return None
        if json_str[start:].startswith("true"):
            return "true"
        if json_str[start:].startswith("false"):
            return "false"

        if json_str[start] == '"':
            end = start + 1
            while end < len(json_str) and json_str[end] != '"':
                if json_str[end] == '\\':
                    end = end + 2
                else:
                    end = end + 1
            if end < len(json_str):
                return json_str[start + 1:end]
        # Number
        if start < len(json_str) and (json_str[start] == '-' or (json_str[start] >= '0' and json_str[start] <= '9')):
            end = start
            while end < len(json_str) and (json_str[end] == '-' or json_str[end] == '.' or (json_str[end] >= '0' and json_str[end] <= '9')):
                end = end + 1
            if end > start:
                return json_str[start:end]
        return None

    # Build JSON payload for create/update
    def payload_str():
        h = hostname if hostname != None else ""
        res_val = "true" if bool(resolved) else "false"
        res6_val = "true" if bool(resolved6) else "false"
        return '{"name":"%s","address":"%s","address6":"%s","comment":"%s","interface":"%s","resolved":%s,"resolved6":%s,"timeout":%s,"hostname":"%s"}' % (
            name, address, address6, comment.replace('"', '\\"'), interface.replace('"', '\\"'),
            res_val, res6_val, str(timeout), h.replace('"', '\\"')
        )

    # State handling
    if state == "absent":
        entry = get_entry_by_name()
        if entry == None:
            return {"changed": False, "msg": "dns host %s does not exist" % name}

        if ctx.check_mode:
            return {"changed": True, "msg": "would remove dns host " + name}

        ref = extract_value(entry, "_ref")
        if ref == None:
            fail("cannot find _ref in existing entry")

        res = ctx.run([
            "curl", "-s", "-k", "-X", "DELETE",
            "-H", "X-Token: " + utm_token,
            base_url + endpoint + "/" + ref
        ])
        if res.rc != 0:
            fail("failed to delete dns host: " + res.stderr)
        return {"changed": True, "msg": "removed dns host " + name}

    # state == "present"
    entry = get_entry_by_name()

    if entry != None:
        # Extract current values for comparison
        current = {
            "comment": extract_value(entry, "comment"),
            "hostname": extract_value(entry, "hostname"),
            "interface": extract_value(entry, "interface"),
            "address": extract_value(entry, "address"),
            "address6": extract_value(entry, "address6"),
            "resolved": extract_value(entry, "resolved"),
            "resolved6": extract_value(entry, "resolved6"),
            "timeout": extract_value(entry, "timeout")
        }

        # Convert resolved fields to bool if present
        resolved_current = bool(current.get("resolved") == "true")
        resolved6_current = bool(current.get("resolved6") == "true")
        timeout_current = 0
        if current.get("timeout") != None and current.get("timeout") != "":
            timeout_current = int(str(current.get("timeout")))

        # Build desired values
        desired = {
            "comment": comment,
            "hostname": hostname,
            "interface": interface,
            "address": address,
            "address6": address6,
            "resolved": bool(resolved),
            "resolved6": bool(resolved6),
            "timeout": int(timeout)
        }

        needs_update = False
        for key in ["comment", "interface", "hostname"]:
            if str(current.get(key)) != str(desired.get(key)):
                needs_update = True
                break

        if current.get("address") != address:
            needs_update = True
        if current.get("address6") != address6:
            needs_update = True
        if resolved_current != desired.get("resolved"):
            needs_update = True
        if resolved6_current != desired.get("resolved6"):
            needs_update = True
        if timeout_current != desired.get("timeout"):
            needs_update = True

        if not needs_update:
            return {"changed": False, "msg": "dns host %s already exists and is up-to-date" % name}

        if ctx.check_mode:
            return {"changed": True, "msg": "would update dns host " + name}

        ref = extract_value(entry, "_ref")
        if ref == None:
            fail("cannot find _ref in existing entry")

        res = ctx.run([
            "curl", "-s", "-k", "-X", "PUT",
            "-H", "X-Token: " + utm_token,
            "-H", "Content-Type: application/json",
            "-d", payload_str(),
            base_url + endpoint + "/" + ref
        ])
        if res.rc != 0:
            fail("failed to update dns host: " + res.stderr)
        return {"changed": True, "msg": "updated dns host " + name}

    # Create new entry
    if ctx.check_mode:
        return {"changed": True, "msg": "would create dns host " + name}

    res = ctx.run([
        "curl", "-s", "-k", "-X", "POST",
        "-H", "X-Token: " + utm_token,
        "-H", "Content-Type: application/json",
        "-d", payload_str(),
        base_url + endpoint
    ])
    if res.rc != 0:
        fail("failed to create dns host: " + res.stderr)
    return {"changed": True, "msg": "created dns host " + name}
