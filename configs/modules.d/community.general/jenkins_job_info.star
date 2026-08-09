def main(ctx, params):
    url = params.get("url", "http://localhost:8080")
    user = params.get("user")
    password = params.get("password")
    token = params.get("token")
    name = params.get("name")
    glob_pattern = params.get("glob")
    color = params.get("color")
    validate_certs = params.get("validate_certs", True)

    # Mutually exclusive checks
    if password and token:
        ctx.fail("password and token are mutually exclusive")
    if name and glob_pattern:
        ctx.fail("name and glob are mutually exclusive")

    # Authentication options
    auth_part = ""
    if user:
        if password:
            auth_part = user + ":" + password + "@"
        elif token:
            auth_part = user + ":" + token + "@"
        else:
            auth_part = user + "@"

    # Build curl command
    base_url = url.rstrip("/")
    if name:
        endpoint = base_url + "/job/" + name + "/api/json"
    else:
        endpoint = base_url + "/api/json"

    curl_argv = ["curl", "-sS", "-f", "-L"]
    if not validate_certs:
        curl_argv.append("-k")
    if auth_part:
        url_with_auth = url.replace("://", "://" + auth_part, 1)
        curl_argv.append(url_with_auth + ("/job/" + name + "/api/json" if name else "/api/json"))
    else:
        curl_argv.append(endpoint)

    # Execute GET request
    res = ctx.run(curl_argv, mutates=False)
    if res.skipped:
        return {"changed": False, "msg": "would fetch job info"}

    if res.rc != 0:
        ctx.fail("Failed to fetch job info from Jenkins: " + res.stderr)

    raw = res.stdout
    raw = "".join(raw.split())
    if not raw.startswith("{") or not raw.endswith("}"):
        ctx.fail("Jenkins did not return valid JSON")

    jobs = []

    if name:
        job = _parse_job(raw)
        if job:
            jobs.append(job)
    else:
        jobs_start = raw.find('"jobs":[')
        if jobs_start == -1:
            ctx.fail("Jenkins response missing 'jobs' field")
        jobs_str = raw[jobs_start + 8:]
        if not jobs_str.startswith('['):
            ctx.fail("Invalid jobs list format")
        bracket_depth = 0
        i = 0
        while i < len(jobs_str):
            if jobs_str[i] == '[':
                bracket_depth += 1
            elif jobs_str[i] == ']':
                bracket_depth -= 1
                if bracket_depth == 0:
                    jobs_content = jobs_str[1:i]
                    i = len(jobs_str) + 1
                    break
            i += 1
        if i < len(jobs_str):
            ctx.fail("Malformed jobs list: missing closing bracket")

        objects = _split_json_objects(jobs_content)
        for obj_str in objects:
            job = _parse_job(obj_str)
            if job:
                jobs.append(job)

    if glob_pattern:
        filtered = []
        for job in jobs:
            if _glob_match(job["fullname"], glob_pattern):
                filtered.append(job)
        jobs = filtered

    if color:
        jobs = [j for j in jobs if j["color"] == color]

    return {"changed": False, "msg": "Fetched job info", "data": {"jobs": jobs}}


def _parse_job(job_str):
    name = _extract_string_field(job_str, "name")
    fullname = _extract_string_field(job_str, "fullName")
    url = _extract_string_field(job_str, "url")
    color = _extract_string_field(job_str, "color")

    if name == None or fullname == None or url == None or color == None:
        return None

    return {
        "name": name,
        "fullname": fullname,
        "url": url,
        "color": color
    }


def _extract_string_field(json_str, field_name):
    prefix = '"' + field_name + '":"'
    start = json_str.find(prefix)
    if start == -1:
        return None
    start += len(prefix)
    end = start
    while end < len(json_str):
        if json_str[end] == '"':
            return json_str[start:end]
        end += 1
    return None


def _split_json_objects(content):
    objects = []
    start = 0
    depth = 0
    for i, c in enumerate(content):
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                obj = content[start:i+1].strip()
                if obj:
                    objects.append(obj)
                start = i + 1
                while start < len(content) and (content[start] == ',' or content[start].isspace()):
                    start += 1
    return objects


def _glob_match(text, pattern):
    if not pattern:
        return text == ""
    if pattern == "*":
        return True

    parts = pattern.split("*")
    i = 0
    for part in parts:
        if i + len(part) > len(text):
            return False
        if text[i:i+len(part)] != part:
            return False
        i += len(part)
    return i <= len(text)
