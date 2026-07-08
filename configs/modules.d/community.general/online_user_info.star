def main(ctx, params):
    api_token = params.get("api_token")
    if api_token == None:
        fail("api_token is required")
    
    api_url = params.get("api_url", "https://api.online.net")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)

    # Build curl command to fetch user info
    curl_args = [
        "curl",
        "-s",
        "-X", "GET",
        "-H", "Authorization: Bearer " + api_token,
        "-H", "Accept: application/json",
        api_url + "/api/v1/user"
    ]

    # Add SSL validation control if needed
    if validate_certs == False:
        curl_args.append("-k")

    res = ctx.run(curl_args, mutates=False)
    
    if res.rc != 0:
        fail("failed to retrieve user info: " + res.stderr)

    # Parse JSON manually (basic extraction)
    content = res.stdout
    if content.find('"id"') == -1:
        fail("invalid JSON response from API")

    # Extract basic fields using string operations
    def get_str_field(content, key):
        pattern = '"' + key + '": "'
        idx = content.find(pattern)
        if idx == -1:
            return ""
        start = idx + len(pattern)
        end = content.find('"', start)
        if end == -1:
            return ""
        return content[start:end]
    
    def get_int_field(content, key):
        pattern = '"' + key + '": '
        idx = content.find(pattern)
        if idx == -1:
            return 0
        start = idx + len(pattern)
        end = content.find(',', start)
        if end == -1:
            end = content.find('}', start)
        if end == -1:
            end = len(content)
        num_str = content[start:end].strip()
        # Starlark has no try/except, so check for digits first
        if num_str == "":
            return 0
        for c in num_str:
            if c < '0' or c > '9':
                return 0
        return int(num_str)

    user_info = {
        "id": get_int_field(content, "id"),
        "login": get_str_field(content, "login"),
        "first_name": get_str_field(content, "first_name"),
        "last_name": get_str_field(content, "last_name"),
        "email": get_str_field(content, "email"),
        "company": get_str_field(content, "company")
    }

    return {
        "changed": False,
        "msg": "user information retrieved successfully",
        "data": {
            "online_user_info": user_info
        }
    }
