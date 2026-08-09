def main(ctx, params):
    url = params["url"]
    api_token = params["api_token"]
    job_id = params["job_id"]
    api_version = params.get("api_version", 39)
    offset = params.get("offset", 0)
    max_results = params.get("max", 20)
    status = params.get("status", "")

    # Validate API version
    if api_version < 14:
        fail("API version should be at least 14")

    # Build query string
    query = "offset=%s&max=%s" % (offset, max_results)
    if status:
        query += "&status=" + status

    endpoint = "api/%s/job/%s/executions?%s" % (api_version, job_id, query)
    full_url = url.rstrip("/") + "/" + endpoint.lstrip("/")

    # Build curl arguments
    argv = [
        "curl",
        "-s",
        "-f",
        "-X", "GET",
        "-H", "X-Rundeck-Auth-Token: " + api_token,
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        full_url
    ]

    if not params.get("validate_certs", True):
        argv.extend(["-k"])

    if params.get("client_cert") and params.get("client_key"):
        argv.extend(["--cert", params["client_cert"], "--key", params["client_key"]])
    elif params.get("client_cert"):
        argv.extend(["--cert", params["client_cert"]])

    if params.get("url_username"):
        if params.get("url_password"):
            argv.extend(["-u", params["url_username"] + ":" + params["url_password"]])
        else:
            argv.extend(["-u", params["url_username"]])

    agent = params.get("http_agent", "ansible-httpget")
    argv.extend(["-H", "User-Agent: " + agent])

    res = ctx.run(argv)

    if res.skipped:
        return {
            "changed": False,
            "msg": "would fetch job executions",
            "data": {
                "executions": [],
                "paging": {
                    "count": 0,
                    "total": 0,
                    "offset": offset,
                    "max": max_results
                }
            }
        }

    if res.rc != 0:
        fail("failed to fetch job executions: " + res.stderr)

    response = res.stdout

    # Extract paging offset
    offset_pos = response.find('"offset":')
    paging_offset = offset
    if offset_pos != -1:
        rest = response[offset_pos + 9:]
        val = ""
        for c in rest:
            if c in "0123456789":
                val += c
            else:
                break
        if val != "":
            paging_offset = int(val)

    # Extract paging max
    max_pos = response.find('"max":')
    paging_max = max_results
    if max_pos != -1:
        rest = response[max_pos + 6:]
        val = ""
        for c in rest:
            if c in "0123456789":
                val += c
            else:
                break
        if val != "":
            paging_max = int(val)

    # Extract paging total
    total_pos = response.find('"total":')
    paging_total = 0
    if total_pos != -1:
        rest = response[total_pos + 8:]
        val = ""
        for c in rest:
            if c in "0123456789":
                val += c
            else:
                break
        if val != "":
            paging_total = int(val)

    # Count executions by counting "id":
    id_count = 0
    idx = 0
    while True:
        pos = response.find('"id":', idx)
        if pos == -1:
            break
        id_count += 1
        idx = pos + 1

    paging = {
        "count": id_count,
        "total": paging_total,
        "offset": paging_offset,
        "max": paging_max
    }

    return {
        "changed": False,
        "msg": "Executions info result",
        "data": {
            "executions": response,
            "paging": paging
        }
    }
