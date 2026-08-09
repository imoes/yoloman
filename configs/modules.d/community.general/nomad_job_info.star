def main(ctx, params):
    host = params["host"]
    port = params.get("port", 4646)
    use_ssl = params.get("use_ssl", True)
    timeout = params.get("timeout", 5)
    validate_certs = params.get("validate_certs", True)
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    namespace = params.get("namespace")
    name = params.get("name")
    token = params.get("token")

    # Build curl command for Nomad API
    scheme = "https" if use_ssl else "http"
    base_url = "%s://%s:%d/v1" % (scheme, host, port)

    # Build headers list
    headers = ["-H", "Accept: application/json"]
    if token != None:
        headers += ["-H", "X-Nomad-Token: " + token]
    if namespace != None:
        # Namespace in query string, not header
        pass

    # Build curl arguments
    curl_args = [
        "curl", "-sS", "-X", "GET",
        "--connect-timeout", str(timeout)
    ]
    if not validate_certs:
        curl_args += ["-k"]
    if client_cert != None and client_key != None:
        curl_args += ["--cert", client_cert, "--key", client_key]
    elif client_cert != None or client_key != None:
        fail("both client_cert and client_key must be specified together")

    # Get jobs list
    list_url = base_url + "/jobs"
    if namespace != None:
        list_url += "?namespace=" + namespace

    res = ctx.run(curl_args + ["-H", "Accept: application/json", list_url])
    if res.rc != 0:
        fail("failed to list jobs: " + res.stderr)

    job_list = _parse_json(res.stdout)

    # If specific job requested, fetch it directly
    if name != None:
        # Try to find in list first
        found = False
        for job in job_list:
            if job.get("ID") == name:
                found = True
                break

        if not found:
            # Try direct lookup (may still exist)
            job_url = base_url + "/job/" + name
            if namespace != None:
                job_url += "?namespace=" + namespace
            res2 = ctx.run(curl_args + ["-H", "Accept: application/json", job_url])
            if res2.rc != 0:
                fail("job '%s' not found: %s" % (name, res2.stderr))

            result = [_parse_json(res2.stdout)]
        else:
            # Get details for the matched job
            job_url = base_url + "/job/" + name
            if namespace != None:
                job_url += "?namespace=" + namespace
            res3 = ctx.run(curl_args + ["-H", "Accept: application/json", job_url])
            if res3.rc != 0:
                fail("failed to get job details for '%s': %s" % (name, res3.stderr))

            result = [_parse_json(res3.stdout)]
    else:
        # Get details for all jobs
        result = []
        for job in job_list:
            job_id = job.get("ID")
            if job_id == None:
                continue
            job_url = base_url + "/job/" + job_id
            if namespace != None:
                job_url += "?namespace=" + namespace
            res_job = ctx.run(curl_args + ["-H", "Accept: application/json", job_url])
            if res_job.rc != 0:
                # Skip jobs that can't be fetched
                continue
            job_detail = _parse_json(res_job.stdout)
            result.append(job_detail)

    return {"changed": False, "msg": "fetched job info", "data": {"result": result}}


def _parse_json(text):
    # Simple JSON parser using only Starlark builtins
    # This is a minimal parser for the Nomad API responses
    s = text.strip()
    if s == "":
        fail("empty JSON response")

    # Handle top-level objects/arrays
    if s.startswith("["):
        return _parse_array(s)
    elif s.startswith("{"):
        return _parse_object(s)
    else:
        fail("expected JSON object or array, got: " + s[:20])


def _parse_array(s):
    # Remove brackets
    s = s.strip()[1:-1].strip()
    if s == "":
        return []

    items = []
    depth = 0
    current = ""
    i = 0
    while i < len(s):
        c = s[i]
        if c in "{[":
            depth += 1
            current += c
        elif c in "}]":
            depth -= 1
            current += c
        elif c == "," and depth == 0:
            items.append(_parse_json_impl(current.strip()))
            current = ""
        else:
            current += c
        i += 1
    if current.strip() != "":
        items.append(_parse_json_impl(current.strip()))
    return items


def _parse_object(s):
    # Remove braces
    s = s.strip()[1:-1].strip()
    if s == "":
        return {}

    obj = {}
    depth = 0
    current = ""
    i = 0
    while i < len(s):
        c = s[i]
        if c in "\"'":
            # Handle quoted strings
            quote = c
            current += c
            i += 1
            while i < len(s) and s[i] != quote:
                if s[i] == "\\" and i + 1 < len(s):
                    current += s[i:i+2]
                    i += 2
                else:
                    current += s[i]
                    i += 1
            if i < len(s):
                current += s[i]  # closing quote
        elif c in "{[":
            depth += 1
            current += c
        elif c in "}]":
            depth -= 1
            current += c
        elif c == "," and depth == 0:
            _add_key_value(current.strip(), obj)
            current = ""
        else:
            current += c
        i += 1
    if current.strip() != "":
        _add_key_value(current.strip(), obj)
    return obj


def _parse_json_impl(s):
    s = s.strip()
    if s == "":
        fail("empty JSON response")

    # Handle top-level objects/arrays
    if s.startswith("["):
        return _parse_array(s)
    elif s.startswith("{"):
        return _parse_object(s)
    else:
        fail("expected JSON object or array, got: " + s[:20])


def _add_key_value(pair, obj):
    if pair == "":
        return
    idx = pair.find(":")
    if idx == -1:
        return
    key = pair[:idx].strip().strip("\"'")
    value = pair[idx+1:].strip()
    obj[key] = _parse_json_impl(value)
