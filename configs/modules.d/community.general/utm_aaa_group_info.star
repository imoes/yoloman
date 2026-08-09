def main(ctx, params):
    name = params["name"]
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)
    state = params.get("state", "present")
    
    if state == "absent":
        fail("module does not support state=absent — it is an info module")

    # Build URL
    url = "%s://%s:%d/aaa/group" % (utm_protocol, utm_host, utm_port)

    # Build curl command with headers
    cmd = [
        "curl",
        "-s",
        "-X", "GET",
        "-H", "Authorization: Bearer %s" % utm_token,
        "-H", "Content-Type: application/json",
        url
    ]
    
    # Add --insecure if not validating certs
    if not validate_certs:
        cmd = cmd + ["--insecure"]

    # Fetch data
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("failed to fetch aaa/groups: " + res.stderr)

    # Parse JSON manually (Starlark has no json module)
    # Expecting array of objects; search for matching name
    output = res.stdout
    if output == "":
        fail("empty response from UTM API")
    
    # Very basic JSON array parser for known structure
    # Skip whitespace, look for '['
    i = 0
    while i < len(output) and output[i] in " \t\n\r":
        i += 1
    if i >= len(output) or output[i] != '[':
        fail("unexpected response format: expected array start '['")
    i += 1
    
    # Skip to first '{'
    while i < len(output) and output[i] in " \t\n\r":
        i += 1
    
    # Simple search for objects matching name
    found = False
    result_obj = None
    while i < len(output):
        # Find next '{'
        start = output.find("{", i)
        if start == -1:
            break
        # Find matching '}'
        depth = 1
        j = start + 1
        while j < len(output) and depth > 0:
            if output[j] == '{':
                depth += 1
            elif output[j] == '}':
                depth -= 1
            j += 1
        if depth != 0:
            j = start + 1024  # fallback
        if j > len(output):
            j = len(output)
        obj_str = output[start:j]
        
        # Extract "name": "value"
        name_key = '"name"'
        idx = obj_str.find(name_key)
        if idx != -1:
            # Find colon and string after
            colon_idx = obj_str.find(":", idx + len(name_key))
            if colon_idx != -1:
                # Skip whitespace and quotes
                q1 = obj_str.find('"', colon_idx + 1)
                if q1 != -1:
                    q2 = obj_str.find('"', q1 + 1)
                    if q2 != -1:
                        obj_name = obj_str[q1 + 1:q2]
                        if obj_name == name:
                            result_obj = obj_str
                            found = True
                            break
        
        i = j
    
    if not found:
        # Not found is acceptable for an info module — return empty result
        return {"changed": False, "msg": "aaa group %s not found" % name, "data": {}}

    # Parse JSON object string into dict manually (simplified for known keys)
    # We only need to expose a minimal consistent structure
    def extract_string(obj, key):
        needle = '"' + key + '":'
        idx = obj.find(needle)
        if idx == -1:
            return ""
        start = obj.find('"', idx + len(needle))
        if start == -1:
            return ""
        end = obj.find('"', start + 1)
        if end == -1:
            return ""
        return obj[start + 1:end]
    
    def extract_bool(obj, key):
        needle = '"' + key + '":'
        idx = obj.find(needle)
        if idx == -1:
            return False
        rest = obj[idx + len(needle):].strip()
        if rest.startswith("true"):
            return True
        if rest.startswith("false"):
            return False
        return False
    
    # Build result dict
    ref = extract_string(result_obj, "_ref")
    locked = extract_bool(result_obj, "_locked")
    typ = extract_string(result_obj, "_type")
    _name = extract_string(result_obj, "name")
    adirectory_groups = extract_string(result_obj, "adirectory_groups")
    backend_match = extract_string(result_obj, "backend_match")
    comment = extract_string(result_obj, "comment")
    dynamic = extract_string(result_obj, "dynamic")
    ipsec_dn = extract_string(result_obj, "ipsec_dn")
    ldap_attribute = extract_string(result_obj, "ldap_attribute")
    ldap_attribute_value = extract_string(result_obj, "ldap_attribute_value")
    network = extract_string(result_obj, "network")
    radius_group = extract_string(result_obj, "radius_group")
    tacacs_group = extract_string(result_obj, "tacacs_group")
    members = []
    
    # Parse members list (simplified: split on commas between quotes)
    members_str = extract_string(result_obj, "members")
    if members_str != "":
        for item in members_str.split(","):
            item = item.strip()
            if item.startswith('"') and item.endswith('"'):
                item = item[1:-1]
            if item != "":
                members.append(item)

    # Build result dict
    result = {
        "_ref": ref,
        "_locked": locked,
        "_type": typ,
        "name": _name,
        "adirectory_groups": adirectory_groups,
        "backend_match": backend_match,
        "comment": comment,
        "dynamic": dynamic,
        "ipsec_dn": ipsec_dn,
        "ldap_attribute": ldap_attribute,
        "ldap_attribute_value": ldap_attribute_value,
        "network": network,
        "radius_group": radius_group,
        "tacacs_group": tacacs_group,
        "members": members
    }
    
    return {"changed": False, "msg": "aaa group %s found" % name, "data": result}
