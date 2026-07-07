def main(ctx, params):
    api_key = params["api_key"]
    category = params["category"]
    title = params["title"]
    description = params["description"]
    duration = params.get("duration", 0)
    start = params.get("start")
    stop = params.get("stop")

    # Compute start and stop timestamps
    now = int(ctx.run(["date", "+%s"], mutates=False).stdout.strip())
    if start == None:
        start = now
    if stop == None:
        stop = start + duration

    # Build request payload manually (no JSON module available)
    payload = (
        '{"start":' + str(start) + ',' +
        '"stop":' + str(stop) + ',' +
        '"category":' + json_escape(category) + ',' +
        '"description":' + json_escape(description) + ',' +
        '"title":' + json_escape(title) + '}'
    )

    # Build headers
    headers = (
        "-H", "X-Circonus-App-Name: ansible",
        "-H", "Host: api.circonus.com",
        "-H", "X-Circonus-Auth-Token: " + api_key,
        "-H", "Accept: application/json",
        "-H", "Content-Type: application/json"
    )

    # Execute POST request
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "https://api.circonus.com/v2/annotation"] +
        list(headers) + ["-d", payload],
        mutates=True
    )

    if res.skipped:
        return {"changed": True, "msg": "would create annotation"}

    if res.rc != 0:
        fail("failed to create annotation: " + res.stderr)

    # Parse JSON response manually (simple extraction of _cid for return data)
    resp_text = res.stdout
    if '"_cid":' not in resp_text:
        fail("invalid response from Circonus API: missing _cid field")

    annotation_cid = extract_json_string(resp_text, "_cid")
    return {
        "changed": True,
        "msg": "annotation created",
        "data": {"annotation": {"_cid": annotation_cid}}
    }


def json_escape(s):
    # Minimal JSON string escaping for category/title/description
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return '"' + s + '"'


def extract_json_string(text, key):
    # naive extraction of "key":"value" from JSON
    prefix = '"' + key + '":"'
    if prefix not in text:
        # fallback: look for key without quotes if needed
        prefix = '"' + key + '":'
        idx = text.find(prefix)
        if idx == -1:
            fail("could not extract " + key + " from response")
        idx += len(prefix)
        # numeric or null case
        return text[idx:text.find(",", idx)].strip()
    idx = text.find(prefix)
    if idx == -1:
        fail("could not extract " + key + " from response")
    idx += len(prefix)
    end = idx
    while end < len(text):
        if text[end] == '\\' and end + 1 < len(text):
            end += 2
            continue
        if text[end] == '"':
            break
        end += 1
    return text[idx:end]
