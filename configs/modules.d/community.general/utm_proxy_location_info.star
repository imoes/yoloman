def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)
    headers = params.get("headers", {})

    if state != "present":
        fail("state must be 'present' for info modules")

    # Build URL
    base_url = utm_protocol + "://" + utm_host + ":" + str(utm_port) + "/api/objects/" + endpoint
    endpoint = "reverse_proxy/location"

    # Construct request URL
    url = base_url + "/" + name

    # Build headers
    header_list = ["Authorization: Bearer " + utm_token, "Content-Type: application/json"]
    for k, v in headers.items():
        header_list.append(str(k) + ": " + str(v))

    # Perform GET request
    res = ctx.run(["curl", "-s", "-k" if not validate_certs else "", "-X", "GET", "-H", " -H ".join(header_list), url])
    if res.rc != 0:
        fail("failed to fetch proxy location info: " + res.stderr)

    # Parse JSON manually (no json module)
    stdout = res.stdout
    # Simple JSON extraction for known keys (sophos UTM format)
    result = {}
    lines = stdout.split("\n")
    for line in lines:
        # Basic key-value extraction from JSON-like structure
        line = line.strip()
        if line.startswith('"') and ':' in line:
            parts = line.split(":", 1)
            if len(parts) == 2:
                key = parts[0].strip('" ')
                val = parts[1].strip().rstrip(",")
                # Clean up quotes and simple values
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                elif val == "true":
                    val = True
                elif val == "false":
                    val = False
                elif val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
                    val = int(val)
                result[key] = val

    # If nothing found, try fallback: search for 'name' in JSON
    if not result and 'name' in stdout:
        fail("failed to parse proxy location object")

    return {"changed": False, "msg": "fetched proxy location info", "data": result}
