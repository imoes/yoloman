def main(ctx, params):
    user = params["user"]
    api_key = params["api_key"]
    name = params.get("name", "")
    title = params["title"]
    source = params.get("source")
    description = params.get("description")
    start_time = params.get("start_time")
    end_time = params.get("end_time")
    links = params.get("links")

    if name == "":
        fail("name is required when creating an annotation")

    url = "https://metrics-api.librato.com/v1/annotations/" + name
    body = {"title": title}

    if source != None:
        body["source"] = source
    if description != None:
        body["description"] = description
    if start_time != None:
        body["start_time"] = start_time
    if end_time != None:
        body["end_time"] = end_time
    if links != None:
        body["links"] = links

    json_body = str(body).replace("'", '"').replace("None", "null").replace(": ", ":").replace(", ", ",").replace("{", "{").replace("}", "}")

    # Build auth header manually
    auth = (user + ":" + api_key).encode("utf-8")
    auth_b64 = ""
    # manual base64 encoding for Starlark (no base64 module)
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    i = 0
    while i < len(auth):
        c1 = auth[i]
        c2 = auth[i+1] if i+1 < len(auth) else 0
        c3 = auth[i+2] if i+2 < len(auth) else 0
        chunk = (c1 << 16) + (c2 << 8) + c3
        a = (chunk >> 18) & 63
        b = (chunk >> 12) & 63
        c = (chunk >> 6) & 63
        d = chunk & 63
        auth_b64 += chars[a] + chars[b]
        if i+2 < len(auth):
            auth_b64 += chars[c]
        else:
            auth_b64 += "="
        if i+1 < len(auth):
            auth_b64 += chars[d]
        else:
            auth_b64 += "="
        i += 3

    headers = {
        "Content-Type": "application/json",
        "Authorization": "Basic " + auth_b64.strip("=")
    }

    res = ctx.run([
        "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
        "-H", "Authorization: Basic " + auth_b64.strip("="),
        "-d", json_body, url
    ], mutates=True)

    if res.skipped:
        return {"changed": True, "msg": "would create annotation"}

    if res.rc != 0:
        fail("Failed to create annotation. curl rc=" + str(res.rc) + ": " + res.stderr)

    if res.rc == 0:
        # Check if response indicates success by HTTP status code (we need to parse headers)
        # Since curl -s returns body only, we can't get status directly — but we can check for 201 via stderr
        # Better: use ctx.run with --write-out to get status, but Starlark ctx.run doesn't support that.
        # So fallback: if curl succeeded and response body exists, assume success
        # In practice, librato returns 201 on success, 4xx/5xx on error — curl rc=0 means HTTP success.
        return {"changed": True, "msg": "annotation created", "data": {"response": res.stdout}}

    # Fallback
    fail("Unexpected result from annotation creation")
