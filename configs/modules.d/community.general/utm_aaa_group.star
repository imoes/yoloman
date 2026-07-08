def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)

    headers = dict(params.get("headers", {}))
    headers["X-Token"] = utm_token
    headers["Content-Type"] = "application/json"

    base_url = "%s://%s:%d" % (utm_protocol, utm_host, utm_port)

    # Build request payload
    payload = {"name": name}
    optional_keys = [
        "adirectory_groups", "adirectory_groups_sids", "backend_match",
        "comment", "dynamic", "edirectory_groups", "ipsec_dn",
        "ldap_attribute", "ldap_attribute_value", "members",
        "network", "radius_groups", "tacacs_groups"
    ]
    for key in optional_keys:
        if key in params:
            payload[key] = params[key]

    # Fetch existing object
    res = ctx.run([
        "curl", "-s", "-k",
        "-H", "Content-Type: application/json",
        "-H", "X-Token: " + utm_token,
        "%s/api/aaa/group/%s" % (base_url, name)
    ])
    existing = None
    if res.rc == 0:
        content = res.stdout.strip()
        if content.startswith("{") and content.endswith("}"):
            existing = _parse_json(content)

    # Handle absent state
    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "aaa group %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete aaa group %s" % name}
        res = ctx.run([
            "curl", "-s", "-k", "-X", "DELETE",
            "-H", "Content-Type: application/json",
            "-H", "X-Token: " + utm_token,
            "%s/api/aaa/group/%s" % (base_url, name)
        ])
        if res.rc != 0:
            fail("failed to delete aaa group %s: %s" % (name, res.stderr))
        return {"changed": True, "msg": "deleted aaa group %s" % name}

    # Handle present state
    if existing != None:
        # Check if update needed
        needs_update = False
        for key in ["comment", "adirectory_groups", "adirectory_groups_sids",
                    "backend_match", "dynamic", "edirectory_groups",
                    "ipsec_dn", "ldap_attribute", "ldap_attribute_value",
                    "members", "network", "radius_groups", "tacacs_groups"]:
            old_val = existing.get(key)
            new_val = payload.get(key)
            if old_val != new_val:
                needs_update = True
                break

        if not needs_update:
            return {"changed": False, "msg": "aaa group %s already correct" % name}

        if ctx.check_mode:
            return {"changed": True, "msg": "would update aaa group %s" % name}

        res = ctx.run([
            "curl", "-s", "-k", "-X", "PUT",
            "-H", "Content-Type: application/json",
            "-H", "X-Token: " + utm_token,
            "-d", _to_json(payload),
            "%s/api/aaa/group/%s" % (base_url, name)
        ])
        if res.rc != 0:
            fail("failed to update aaa group %s: %s" % (name, res.stderr))
        return {"changed": True, "msg": "updated aaa group %s" % name}

    # Create new object
    if ctx.check_mode:
        return {"changed": True, "msg": "would create aaa group %s" % name}

    res = ctx.run([
        "curl", "-s", "-k", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "X-Token: " + utm_token,
        "-d", _to_json(payload),
        "%s/api/aaa/group" % base_url
    ])
    if res.rc != 0:
        fail("failed to create aaa group %s: %s" % (name, res.stderr))
    return {"changed": True, "msg": "created aaa group %s" % name}


def _parse_json(s):
    result = {}
    s = s.strip()[1:-1]  # strip { and }
    if not s:
        return result

    # Split by top-level commas (naive, but sufficient for flat objects)
    items = s.split(",")
    for item in items:
        item = item.strip()
        if not item:
            continue
        if ':' not in item:
            continue
        key_part, val_part = item.split(':', 1)
        key = key_part.strip().strip('"')
        val = val_part.strip()
        # Handle string value
        if val.startswith('"') and val.endswith('"'):
            result[key] = val[1:-1]
        # Handle int value
        elif val.isdigit():
            result[key] = int(val)
        # Handle boolean
        elif val == "true":
            result[key] = True
        elif val == "false":
            result[key] = False
        # Handle empty object
        elif val == "{}":
            result[key] = {}
    return result


def _to_json(obj):
    if type(obj) == "dict":
        parts = []
        for k in sorted(obj.keys()):
            v = obj[k]
            if type(v) == "string":
                parts.append('"%s":"%s"' % (k, v))
            elif type(v) == "bool":
                parts.append('"%s":%s' % (k, "true" if v else "false"))
            elif type(v) == "int":
                parts.append('"%s":%d' % (k, v))
            elif type(v) == "list":
                items = []
                for item in v:
                    items.append('"%s"' % item)
                parts.append('"%s":[%s]' % (k, ",".join(items)))
            elif type(v) == "dict":
                inner = []
                for ik in sorted(v.keys()):
                    iv = v[ik]
                    inner.append('"%s":"%s"' % (ik, iv))
                parts.append('"%s":{%s}' % (k, ",".join(inner)))
            else:
                parts.append('"%s":"%s"' % (k, str(v)))
        return "{" + ",".join(parts) + "}"
    elif type(obj) == "string":
        return '"' + obj + '"'
    elif type(obj) == "bool":
        return "true" if obj else "false"
    elif type(obj) == "int":
        return str(obj)
    else:
        return str(obj)
