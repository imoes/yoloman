def main(ctx, params):
    name = params["name"]
    docker_cli = params.get("docker_cli", "docker")
    docker_host = params.get("docker_host", "unix:///var/run/docker.sock")
    tls = params.get("tls", False)
    validate_certs = params.get("validate_certs", False)
    tls_hostname = params.get("tls_hostname")
    api_version = params.get("api_version", "auto")
    ca_path = params.get("ca_path")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    cli_context = params.get("cli_context")

    # Build docker CLI arguments
    argv = [docker_cli, "stack", "ps", name, "--format={{json .}}"]
    
    # Apply TLS settings if specified
    if validate_certs or tls:
        # Use https for docker_host if TLS is enabled
        if docker_host.startswith("tcp://"):
            docker_host = "https://" + docker_host[6:]
        elif not docker_host.startswith("unix://"):
            # Assume TLS is desired for non-socket URLs
            if not docker_host.startswith("https://"):
                docker_host = "https://" + docker_host
    
    if docker_host != "unix:///var/run/docker.sock":
        argv = ["--host", docker_host] + argv
    
    # TLS-specific args (skip if unix socket)
    if not docker_host.startswith("unix://"):
        if validate_certs:
            if ca_path:
                argv = ["--tlsverify", "--tlscacert", ca_path] + argv
            else:
                argv = ["--tlsverify"] + argv
        elif tls:
            argv = ["--tls"] + argv
        
        if client_cert and client_key:
            argv = ["--tlscert", client_cert, "--tlskey", client_key] + argv
        elif client_cert or client_key:
            fail("both client_cert and client_key must be specified together")
        
        if tls_hostname:
            argv = ["--tlshostname", tls_hostname] + argv
    
    res = ctx.run(argv, mutates=False)
    if res.skipped:
        return {"changed": False, "msg": "would retrieve stack tasks", "results": []}
    
    if res.rc != 0:
        fail("docker stack ps failed: " + res.stderr)
    
    # Parse JSON lines
    results = []
    stdout = res.stdout.strip()
    if stdout:
        for line in stdout.split("\n"):
            line = line.strip()
            if not line:
                continue
            entry = _parse_json_line(line)
            results.append(entry)
    
    return {
        "changed": False,
        "msg": "retrieved stack tasks",
        "results": results
    }


def _parse_json_line(line):
    line = line.strip()
    if not line.startswith("{") or not line.endswith("}"):
        fail("invalid JSON line: " + line)
    
    result = {}
    inner = line[1:-1].strip()
    if not inner:
        return result
    
    # Split by top-level commas (naive but sufficient for flat objects)
    parts = []
    depth = 0
    current = ""
    for ch in inner:
        if ch == '{' or ch == '[':
            depth += 1
        elif ch == '}' or ch == ']':
            depth -= 1
        elif ch == ',' and depth == 0:
            parts.append(current.strip())
            current = ""
            continue
        current += ch
    if current.strip():
        parts.append(current.strip())
    
    for part in parts:
        colon = part.find(":")
        if colon == -1:
            continue
        key = part[:colon].strip().strip('"')
        value = part[colon+1:].strip()
        
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        
        result[key] = value
    
    return result
