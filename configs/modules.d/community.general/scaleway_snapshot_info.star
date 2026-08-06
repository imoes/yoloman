def main(ctx, params):
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    region = params["region"]
    query_parameters = params.get("query_parameters", {})
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)

    region_mapping = {
        "ams1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "EMEA-NL-EVS": "https://api.scaleway.com/instance/v1/zones/nl-ams-1",
        "par1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "par2": "https://api.scaleway.com/instance/v1/zones/fr-par-2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/instance/v1/zones/fr-par-2",
        "waw1": "https://api.scaleway.com/instance/v1/zones/pl-waw-1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/instance/v1/zones/pl-waw-1",
    }

    if region not in region_mapping:
        fail("unsupported region: " + region)

    base_url = region_mapping[region]
    url = base_url + "/snapshots"

    query = []
    for k, v in query_parameters.items():
        query.append(str(k) + "=" + str(v))

    if len(query) > 0:
        url = url + "?" + "&".join(query)

    curl_args = ["curl", "-sS", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", "--max-time", str(api_timeout)]
    if not validate_certs:
        curl_args.append("-k")
    curl_args.append(url)

    res = ctx.run(curl_args, mutates=False)

    if res.rc != 0:
        fail("failed to fetch snapshots: " + res.stderr)

    parsed = ctx.parse_json(res.stdout)

    snapshots = []
    if "snapshots" in parsed:
        snapshots = parsed["snapshots"]

    return {"changed": False, "msg": "fetched snapshots", "data": {"scaleway_snapshot_info": snapshots}}
