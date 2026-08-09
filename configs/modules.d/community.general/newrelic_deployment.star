def main(ctx, params):
    token = params["token"]
    app_name = params.get("app_name")
    application_id = params.get("application_id")
    changelog = params.get("changelog")
    description = params.get("description")
    revision = params["revision"]
    user = params.get("user")
    validate_certs = params.get("validate_certs", True)
    exact_match = params.get("app_name_exact_match", False)

    # Validate required options
    if app_name == None and application_id == None:
        fail("one of 'app_name' or 'application_id' is required")
    if app_name != None and application_id != None:
        fail("only one of 'app_name' or 'application_id' can be set")
    if exact_match and app_name == None:
        fail("'app_name_exact_match' requires 'app_name'")

    # Determine application ID
    app_id = None
    if application_id != None:
        app_id = application_id
    else:
        # Lookup app by name
        name = quote_str(app_name)
        url = "https://api.newrelic.com/v2/applications.json?filter[name]=" + name
        headers = {"Api-Key": token}
        res = ctx.run(["curl", "-s", "-f", "-X", "GET", "-H", "Api-Key: " + token, url], mutates=False)
        if res.rc != 0:
            fail("Unable to get application list: " + res.stderr)

        apps = parse_json(res.stdout)
        applications = apps.get("applications", [])
        if len(applications) == 0:
            fail('No application found with name "' + app_name + '"')
        if exact_match:
            app_id = None
            for app in applications:
                if app.get("name") == app_name:
                    app_id = str(app.get("id"))
                    break
            if app_id == None:
                fail('No application found with exact name "' + app_name + '"')
        else:
            app_id = str(applications[0].get("id"))

    if app_id == None:
        fail("No application with name " + app_name + " is found in New Relic")

    # Build deployment payload
    deployment = {}
    if changelog != None:
        deployment["changelog"] = changelog
    if description != None:
        deployment["description"] = description
    deployment["revision"] = revision
    if user != None:
        deployment["user"] = user

    # In check_mode: just report we would change
    if ctx.check_mode:
        return {"changed": True, "msg": "would notify New Relic of deployment"}

    # POST deployment
    url = "https://api.newrelic.com/v2/applications/" + quote_str(app_id) + "/deployments.json"
    payload = {"deployment": deployment}
    json_data = dict_to_json(payload)

    # Build curl command with headers and data
    cmd = [
        "curl", "-s", "-f", "-X", "POST", "-H", "Api-Key: " + token,
        "-H", "Content-Type: application/json", "-d", json_data, url
    ]
    if not validate_certs:
        cmd += ["-k"]

    res = ctx.run(cmd, mutates=True)
    if res.rc not in (0, 200, 201):
        fail("Unable to insert deployment marker: " + res.stderr)

    return {"changed": True, "msg": "notified New Relic about deployment"}


def quote_str(s):
    # Minimal URL encoding for [a-zA-Z0-9_.-] unchanged, others %XX
    safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"
    result = ""
    for c in s:
        if c in safe:
            result += c
        else:
            result += "%" + ("%02X" % ord(c))
    return result


def dict_to_json(d):
    # Minimal JSON encoder for flat dict with string/int/bool values only
    items = []
    for k in sorted(d.keys()):
        v = d[k]
        if v == None:
            items.append('"' + k + '": null')
        elif type(v) == "bool":
            items.append('"' + k + '": ' + ("true" if v else "false"))
        elif type(v) == "int":
            items.append('"' + k + '": ' + str(v))
        elif type(v) == "string":
            # escape quotes and backslashes, control chars
            escaped = ""
            for c in v:
                if c == '"':
                    escaped += '\\"'
                elif c == '\\':
                    escaped += '\\\\'
                elif c == '\n':
                    escaped += '\\n'
                elif c == '\r':
                    escaped += '\\r'
                elif c == '\t':
                    escaped += '\\t'
                elif ord(c) < 32:
                    escaped += "\\u%04x" % ord(c)
                else:
                    escaped += c
            items.append('"' + k + '": "' + escaped + '"')
        else:
            fail("unsupported value type for JSON: " + str(type(v)))
    return "{" + ", ".join(items) + "}"


def parse_json(s):
    # Lightweight JSON parser for simple dicts of strings/int/bool/null
    # Only supports flat dicts for New Relic API response
    s = s.strip()
    if not s.startswith("{"):
        fail("expected JSON object")
    obj = {}
    s = s[1:].strip()
    if s.startswith("}"):
        return obj

    # Split into key-value pairs
    parts = s.split(",")
    for part in parts:
        part = part.strip()
        if not part:
            continue
        colon = part.find(":")
        if colon == -1:
            fail("invalid JSON object")
        key = part[:colon].strip()
        val = part[colon+1:].strip()
        if key[0] != '"' or key[-1] != '"':
            fail("invalid JSON key")
        key = key[1:-1]

        if val == "null":
            obj[key] = None
        elif val == "true":
            obj[key] = True
        elif val == "false":
            obj[key] = False
        elif val[0] == '"' and val[-1] == '"':
            obj[key] = val[1:-1]
        elif val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
            obj[key] = int(val)
        else:
            fail("invalid JSON value: " + val)

    return obj
