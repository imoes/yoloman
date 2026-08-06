def main(ctx, params):
    # Required parameters
    api_token = params.get("api_token")
    region = params.get("region")
    if api_token == None:
        fail("api_token is required")
    if region == None:
        fail("region is required")

    # Optional parameters with defaults
    api_timeout = params.get("api_timeout", 30)
    api_url = params.get("api_url", "https://api.scaleway.com")
    query_parameters = params.get("query_parameters", {})
    validate_certs = params.get("validate_certs", True)

    # Map region to API endpoint as per original implementation
    region_map = {
        "ams1": "https://api.scaleway.com/instance/v1/zones/ams1",
        "EMEA-NL-EVS": "https://api.scaleway.com/instance/v1/zones/ams1",
        "par1": "https://api.scaleway.com/instance/v1/zones/par1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/instance/v1/zones/par1",
        "par2": "https://api.scaleway.com/instance/v1/zones/par2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/instance/v1/zones/par2",
        "waw1": "https://api.scaleway.com/instance/v1/zones/waw1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/instance/v1/zones/waw1"
    }
    if region not in region_map:
        fail("unsupported region: " + region)
    api_url = region_map[region] + "/images"

    # Build query parameters list
    query_parts = []
    for k in query_parameters:
        if query_parameters[k] != None:
            query_parts.append(str(k) + "=" + str(query_parameters[k]))
    query_str = "&".join(query_parts)
    full_url = api_url
    if len(query_parts) > 0:
        full_url = api_url + "?" + query_str

    # Perform GET request using curl
    res = ctx.run(
        ["curl", "-sS", "-f", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", full_url],
        mutates=False
    )

    if res.rc != 0:
        fail("scaleway API request failed: " + res.stderr)

    # Parse JSON manually (no json module in Starlark)
    data = res.stdout.strip()
    if not data.startswith("[") or not data.endswith("]"):
        fail("unexpected API response format")
    inner = data[1:-1].strip()
    if len(inner) == 0:
        images = []
    else:
        # Split by "},{" pattern to separate objects
        parts = inner.split("},{")
        # Reconstruct objects
        images = []
        for i in range(len(parts)):
            part = parts[i].strip()
            if i == 0 and not part.startswith("{"):
                part = "{" + part
            if i == len(parts) - 1 and not part.endswith("}"):
                part = part + "}"
            # Remove potential leading/trailing brackets from middle parts
            if i > 0 and part.startswith("{"):
                part = part[1:]
            if i < len(parts) - 1 and part.endswith("}"):
                part = part[:-1]
            images.append(part)

    # Return results
    return {
        "changed": False,
        "msg": "fetched image information",
        "data": {"scaleway_image_info": images}
    }
