def main(ctx, params):
    api_key = params["api_key"]
    poll = params.get("poll", False)
    url = "https://api.memset.com/v1/json"
    
    # Build API payload: api_key is required, no extra fields for dns.reload
    body = "api_key=" + api_key
    
    # Call dns.reload endpoint via curl
    res = ctx.run([
        "curl", "-s", "-X", "POST", "-d", body, url,
        "-H", "Content-Type: application/x-www-form-urlencoded"
    ])
    
    # Parse JSON using only string methods (no json module)
    def parse_json(s):
        result = {}
        s = s.strip()
        if not s.startswith("{") or not s.endswith("}"):
            return None
        s = s[1:-1]  # strip outer braces
        fields = ["error", "finished", "id", "status", "type"]
        for field in fields:
            start = s.find('"' + field + '"')
            if start == -1:
                continue
            start += len(field) + 3  # after '"field":'
            while start < len(s) and s[start] in " \t\n":
                start += 1
            if s[start] == '"':
                start += 1
                end = start
                while end < len(s) and s[end] != '"':
                    if s[end] == '\\' and end + 1 < len(s):
                        end += 2
                    else:
                        end += 1
                result[field] = s[start:end]
            else:
                end = start
                while end < len(s) and s[end] not in ",} \t\n":
                    end += 1
                val = s[start:end]
                if val == "true":
                    result[field] = True
                elif val == "false":
                    result[field] = False
                else:
                    result[field] = val
        return result
    
    if res.rc != 0:
        fail("dns.reload API call failed: " + res.stderr)
    
    api_response = parse_json(res.stdout)
    if api_response == None:
        fail("Failed to parse API response: " + res.stdout)
    
    if not poll:
        return {
            "changed": True,
            "msg": "DNS reload request submitted",
            "data": {"memset_api": api_response}
        }
    
    # Polling enabled — wait up to 30 seconds (6 * 5s intervals)
    job_id = api_response.get("id", "")
    if job_id == "":
        fail("No job_id in dns.reload response")
    
    # Polling helper function
    def poll_job():
        body = "api_key=" + api_key + "&id=" + job_id
        res = ctx.run([
            "curl", "-s", "-X", "POST", "-d", body, url,
            "-H", "Content-Type: application/x-www-form-urlencoded"
        ])
        if res.rc != 0:
            return None, "job.status API call failed: " + res.stderr
        parsed = parse_json(res.stdout)
        if parsed == None:
            return None, "Failed to parse job.status response: " + res.stdout
        return parsed, None
    
    for i in range(6):
        status, err = poll_job()
        if err != None:
            fail(err)
        finished = status.get("finished", False)
        error = status.get("error", False)
        if finished:
            return {
                "changed": True,
                "msg": "DNS reload completed",
                "data": {"memset_api": status}
            }
        # Sleep 5 seconds
        ctx.run(["sleep", "5"])
    
    # Timeout reached
    return {
        "changed": True,
        "msg": "DNS reload submitted but polling timed out after 30 seconds",
        "data": {"memset_api": api_response},
        "stderr": "Reload submitted successfully, but the Memset API returned a job error when attempting to poll the reload status."
    }
