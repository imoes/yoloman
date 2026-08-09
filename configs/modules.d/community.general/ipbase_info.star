def main(ctx, params):
    ip = params.get("ip")
    apikey = params.get("apikey")
    hostname = params.get("hostname", False)
    language = params.get("language", "en")

    base_url = "https://api.ipbase.com/v2/info"
    query_parts = []

    if ip != None:
        query_parts.append("ip=" + ip)
    if apikey != None:
        query_parts.append("apikey=" + apikey)
    if hostname == True:
        query_parts.append("hostname=1")
    if language != None and language != "en":
        query_parts.append("language=" + language)

    url = base_url
    if query_parts:
        url = base_url + "?" + "&".join(query_parts)

    curl_argv = ["curl", "-s", "-f", "-H", "Accept: application/json", "-H", "User-Agent: ansible-community.general.ipbase_info/0.1.0", url]
    res = ctx.run(curl_argv, mutates=False)

    if res.rc != 0:
        fail("The API request to ipbase.com failed: " + res.stderr)

    # Parse JSON using ctx.json_parse (standard extension for Starlark runtimes)
    data = ctx.json_parse(res.stdout)

    return {"changed": False, "msg": "Successfully retrieved IP information", "data": data}
