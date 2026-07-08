def main(ctx, params):
    apikey = params["apikey"]
    monitorid = params["monitorid"]
    state = params["state"]

    if state != "started" and state != "paused":
        fail("state must be 'started' or 'paused'")

    # Build query parameters for status check
    params_status = {
        "apiKey": apikey,
        "monitors": monitorid,
        "format": "json",
        "noJsonCallback": "1"
    }
    query_parts = []
    for k in params_status:
        query_parts.append(k + "=" + params_status[k])
    query_str = "&".join(query_parts)
    full_uri = "https://api.uptimerobot.com/getMonitors?" + query_str

    res = ctx.run(["curl", "-s", "-X", "GET", full_uri])
    if res.rc != 0:
        fail("failed to fetch monitor status: " + res.stderr)

    result = res.stdout.strip()
    # Parse JSON manually (no json module in Starlark)
    # Expected: {"stat":"ok","monitors":[...]}
    if result.find('"stat":"ok"') == -1 and result.find('"stat":"error"') == -1:
        fail("unexpected API response format: " + result)
    
    stat = "ok"
    if result.find('"stat":"error"') != -1:
        stat = "error"

    if stat != "ok":
        msg = "unknown error"
        # Extract message field
        msg_start = result.find('"message":"')
        if msg_start != -1:
            msg_start += 10
            msg_end = result.find('"', msg_start)
            if msg_end != -1:
                msg = result[msg_start:msg_end]
        fail("Uptime Robot API returned error: " + msg)

    # Determine target status
    target_status = 1 if state == "started" else 0

    # Build edit request
    params_edit = {
        "apiKey": apikey,
        "monitorID": monitorid,
        "monitorStatus": str(target_status),
        "format": "json",
        "noJsonCallback": "1"
    }
    query_parts = []
    for k in params_edit:
        query_parts.append(k + "=" + params_edit[k])
    query_str = "&".join(query_parts)
    full_uri = "https://api.uptimerobot.com/editMonitor?" + query_str

    res = ctx.run(["curl", "-s", "-X", "POST", "-d", "", full_uri], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would " + state + " monitor " + monitorid}

    if res.rc != 0:
        fail("failed to " + state + " monitor: " + res.stderr)

    response = res.stdout.strip()
    if response.find('"stat":"ok"') == -1:
        msg = "unknown error"
        msg_start = response.find('"message":"')
        if msg_start != -1:
            msg_start += 10
            msg_end = response.find('"', msg_start)
            if msg_end != -1:
                msg = response[msg_start:msg_end]
        fail("Uptime Robot API returned error when " + state + " monitor: " + msg)

    return {"changed": True, "msg": "successfully " + state + " monitor " + monitorid}
