def main(ctx, params):
    name = params["name"]
    build_number = params.get("build_number")
    user = params.get("user")
    password = params.get("password")
    token = params.get("token")
    url = params.get("url", "http://localhost:8080")

    # Build authentication part of URL if credentials provided
    auth_url = url
    if user:
        if password:
            auth_url = url.replace("://", "://" + user + ":" + password + "@", 1)
        elif token:
            auth_url = url.replace("://", "://" + user + ":" + token + "@", 1)
        else:
            auth_url = url.replace("://", "://" + user + "@", 1)

    # Construct Jenkins API endpoint URL for job build info
    job_path = "job/" + name + "/api/json"
    build_path = ""
    if build_number != None:
        build_path = "/" + str(build_number) + "/api/json"
    else:
        build_path = "/lastBuild/api/json"

    full_url = auth_url + "/" + job_path + build_path

    # Fetch job info
    res = ctx.run(["curl", "-s", "-S", "-f", full_url], mutates=False)
    if res.skipped:
        # check_mode: predict successful fetch
        return {
            "changed": False,
            "msg": "would fetch build info for " + name + (" build " + str(build_number) if build_number else " last build"),
            "data": {
                "name": name,
                "url": url,
                "user": user,
                "build_info": {"result": "PREDICTED"}
            }
        }

    if res.rc != 0:
        # Check for 404 (job/build not found)
        if "404" in res.stderr or "not found" in res.stderr.lower():
            return {
                "changed": False,
                "msg": "job or build not found",
                "data": {
                    "name": name,
                    "url": url,
                    "user": user,
                    "build_info": {"result": "ABSENT"}
                }
            }
        fail("failed to fetch build info: " + res.stderr)

    # Parse JSON manually (no json module allowed)
    content = res.stdout
    # Very minimal JSON parser for expected structure (result, number, etc.)
    def parse_json(s):
        # Skip outer braces and parse key-value pairs
        s = s.strip()
        if not s.startswith("{") or not s.endswith("}"):
            return {}
        s = s[1:-1]
        result = {}
        # naive split by commas at top level (ignores nested braces, but sufficient for known keys)
        # This is a simplified parser for known Jenkins API fields
        depth = 0
        key = ""
        val = ""
        i = 0
        while i < len(s):
            c = s[i]
            if c == '"' and (i == 0 or s[i-1] != '\\'):
                # parse key
                i += 1
                key_start = i
                while i < len(s) and s[i] != '"':
                    i += 1
                key = s[key_start:i]
                i += 1  # skip closing quote
                # skip colon and whitespace
                while i < len(s) and (s[i] == ' ' or s[i] == ':'):
                    i += 1
                # parse value
                if i < len(s) and s[i] == '"':
                    i += 1
                    val_start = i
                    while i < len(s) and (s[i] != '"' or (s[i] == '"' and i > 0 and s[i-1] == '\\')):
                        i += 1
                    val = s[val_start:i]
                    i += 1
                else:
                    # number or boolean
                    val_start = i
                    while i < len(s) and (s[i].isdigit() or s[i] in "+-.eE"):
                        i += 1
                    val = s[val_start:i]
                # store
                result[key] = val
            else:
                i += 1
        return result

    build_info = parse_json(content)
    # Ensure result key exists
    if "result" not in build_info:
        build_info["result"] = "UNKNOWN"

    return {
        "changed": False,
        "msg": "build info retrieved",
        "data": {
            "name": name,
            "url": url,
            "user": user,
            "build_info": build_info
        }
    }
