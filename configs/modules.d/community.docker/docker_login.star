def main(ctx, params):
    state = params.get("state", "present")
    registry_url = params.get("registry_url", "https://index.docker.io/v1/")
    username = params.get("username")
    password = params.get("password")
    reauthorize = params.get("reauthorize", False)
    config_path = params.get("config_path", "~/.docker/config.json")

    # Expand ~ in config_path
    if config_path.startswith("~"):
        home = ctx.run(["echo", "$HOME"]).stdout.strip()
        if home == "":
            fail("Failed to determine home directory")
        config_path = home + config_path[1:]

    # State: absent
    if state == "absent":
        if ctx.check_mode:
            exists = _credentials_exist(ctx, registry_url, config_path)
            return {"changed": exists, "msg": "would log out of " + registry_url if exists else "already logged out"}
        
        if not _credentials_exist(ctx, registry_url, config_path):
            return {"changed": False, "msg": "credentials for " + registry_url + " not present"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would log out of " + registry_url}
        
        # Docker CLI does not support logout with custom config path
        fail("logout with custom config file is not supported by Docker CLI — use default config path")

    # State: present (login)
    if username == None:
        fail("username is required when state is present")
    if password == None:
        fail("password is required when state is present")

    if ctx.check_mode:
        return {"changed": True, "msg": "would log into " + registry_url + " as " + username}

    # Perform login via docker CLI
    docker_login_res = ctx.run([
        "docker", "login", 
        "--username", username,
        "--password-stdin",
        registry_url
    ], mutates=True)

    if docker_login_res.rc != 0:
        fail("docker login failed: " + docker_login_res.stderr)

    return {
        "changed": True,
        "msg": "logged into " + registry_url + " as " + username,
        "login_result": {
            "serveraddress": registry_url,
            "username": username
        }
    }


def _credentials_exist(ctx, registry_url, config_path):
    if not ctx.file_exists(config_path):
        return False
    
    content = ctx.file_read(config_path)
    # Simple search for registry URL in auths section
    # Expected format: "auths":{"registry_url":{"auth":"..."
    registry_quoted = "\"" + registry_url + "\""
    idx = content.find(registry_quoted)
    if idx == -1:
        return False
    
    # Find the object block after the registry URL
    rest = content[idx + len(registry_quoted):]
    # Look for opening brace
    brace_idx = rest.find("{")
    if brace_idx == -1:
        return False
    
    # Extract object content up to matching brace
    brace_count = 1
    i = brace_idx + 1
    while i < len(rest) and brace_count > 0 and i < len(rest):
        if rest[i] == "{":
            brace_count += 1
        elif rest[i] == "}":
            brace_count -= 1
        i += 1
    
    # Check if auth key exists in the extracted block
    return '"auth"' in rest[brace_idx:i]
