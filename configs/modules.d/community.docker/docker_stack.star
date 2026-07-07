def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    compose = params.get("compose", [])
    absent_retries = params.get("absent_retries", 0)
    absent_retries_interval = params.get("absent_retries_interval", 1)
    prune = params.get("prune", False)
    with_registry_auth = params.get("with_registry_auth", False)
    resolve_image = params.get("resolve_image")
    
    docker_cli = params.get("docker_cli", "docker")
    docker_host = params.get("docker_host", "unix:///var/run/docker.sock")
    tls = params.get("tls", False)
    validate_certs = params.get("validate_certs", False)
    cli_context = params.get("cli_context")
    api_version = params.get("api_version", "auto")
    ca_path = params.get("ca_path")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    tls_hostname = params.get("tls_hostname")
    
    # Build docker command base
    cmd_base = [docker_cli]
    if cli_context:
        cmd_base += ["--context", cli_context]
    if api_version != "auto":
        cmd_base += ["--api-version", api_version]
    if docker_host != "unix:///var/run/docker.sock":
        cmd_base += ["--host", docker_host]
    if tls:
        cmd_base += ["--tls"]
    if validate_certs:
        cmd_base += ["--tlsverify"]
    if ca_path:
        cmd_base += ["--tlscacert", ca_path]
    if client_cert:
        cmd_base += ["--tlscert", client_cert]
    if client_key:
        cmd_base += ["--tlskey", client_key]
    if tls_hostname:
        cmd_base += ["--tlshostname", tls_hostname]
    
    # Check if stack exists (for absent state)
    def stack_exists():
        res = ctx.run(cmd_base + ["stack", "inspect", name], mutates=False, ok_codes=[0, 1])
        return res.rc == 0
    
    if state == "absent":
        if not stack_exists():
            return {"changed": False, "msg": "Stack " + name + " does not exist"}
        # Retry loop for stack removal
        retries = absent_retries
        while retries >= 0:
            res = ctx.run(cmd_base + ["stack", "rm", name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would remove stack " + name}
            if res.rc == 0:
                # Verify stack is really gone
                if not stack_exists():
                    return {"changed": True, "msg": "Stack " + name + " removed"}
                # If still exists, retry
                if retries > 0:
                    ctx.run(["sleep", str(absent_retries_interval)], mutates=False)
                retries -= 1
                continue
            # Command failed
            fail("failed to remove stack " + name + ": " + res.stderr)
        
        # Last try failed
        fail("Stack " + name + " still exists after " + str(absent_retries) + " retries")
    
    # state == "present"
    if not compose:
        fail("compose parameter must be a list containing at least one element")
    
    compose_files = []
    for i, compose_def in enumerate(compose):
        if type(compose_def) == type({}):
            # Write YAML dict to temp file
            tmpfile = "/tmp/ansible_stack_" + str(i) + ".yml"
            yaml_content = ""
            for key in sorted(compose_def.keys()):
                val = compose_def[key]
                if type(val) == type(True):
                    yaml_content += key + ": " + ("true" if val else "false") + "\n"
                elif type(val) == type(""):
                    yaml_content += key + ": \"" + val.replace("\"", "\\\"") + "\"\n"
                elif type(val) == type(0):
                    yaml_content += key + ": " + str(val) + "\n"
                elif type(val) == type([]):
                    yaml_content += key + ":\n"
                    for item in val:
                        if type(item) == type(""):
                            yaml_content += "  - " + item + "\n"
                        else:
                            yaml_content += "  - " + str(item) + "\n"
                elif type(val) == type({}):
                    yaml_content += key + ":\n"
                    for k2 in sorted(val.keys()):
                        v2 = val[k2]
                        if type(v2) == type(""):
                            yaml_content += "  " + k2 + ": \"" + v2.replace("\"", "\\\"") + "\"\n"
                        elif type(v2) == type(True):
                            yaml_content += "  " + k2 + ": " + ("true" if v2 else "false") + "\n"
                        else:
                            yaml_content += "  " + k2 + ": " + str(v2) + "\n"
                else:
                    yaml_content += key + ": " + str(val) + "\n"
            changed_file = ctx.file_write(tmpfile, yaml_content, "0600")
            if changed_file:
                compose_files.append(tmpfile)
            else:
                # File already existed with same content, assume it's valid
                compose_files.append(tmpfile)
        elif type(compose_def) == type(""):
            # Use path as-is
            compose_files.append(compose_def)
        else:
            fail("compose element must be a string or a dictionary")
    
    # Get current services (if stack exists)
    before_services = {}
    if stack_exists():
        res = ctx.run(cmd_base + ["stack", "services", name, "--format", "{{.Name}}"], mutates=False)
        if res.rc == 0:
            services = res.stdout.strip().split("\n") if res.stdout.strip() else []
            for svc in services:
                svc = svc.strip()
                if svc:
                    inspect_res = ctx.run(cmd_base + ["service", "inspect", svc], mutates=False, ok_codes=[0])
                    if inspect_res.rc == 0:
                        before_services[svc] = _parse_service_spec(inspect_res.stdout)
    
    # Deploy stack
    deploy_cmd = cmd_base + ["stack", "deploy"]
    if prune:
        deploy_cmd.append("--prune")
    if with_registry_auth:
        deploy_cmd.append("--with-registry-auth")
    if resolve_image:
        deploy_cmd += ["--resolve-image", resolve_image]
    for cf in compose_files:
        deploy_cmd += ["--compose-file", cf]
    deploy_cmd.append(name)
    
    res = ctx.run(deploy_cmd, mutates=True)
    if res.skipped:
        # Predicted change — need to compute diff
        changed = not stack_exists()
        msg = "would deploy stack " + name
        if changed:
            msg = "would deploy/modify stack " + name
        return {"changed": True, "msg": msg}
    
    if res.rc != 0:
        fail("docker stack deploy command failed: " + res.stderr)
    
    # Get after state
    after_services = {}
    if stack_exists():
        res = ctx.run(cmd_base + ["stack", "services", name, "--format", "{{.Name}}"], mutates=False)
        if res.rc == 0:
            services = res.stdout.strip().split("\n") if res.stdout.strip() else []
            for svc in services:
                svc = svc.strip()
                if svc:
                    inspect_res = ctx.run(cmd_base + ["service", "inspect", svc], mutates=False, ok_codes=[0])
                    if inspect_res.rc == 0:
                        after_services[svc] = _parse_service_spec(inspect_res.stdout)
    
    # Compare services (simplified diff)
    diff = {}
    all_services = set(list(before_services.keys()) + list(after_services.keys()))
    for svc in all_services:
        if svc not in before_services:
            diff[svc] = "added"
        elif svc not in after_services:
            diff[svc] = "removed"
        elif before_services[svc] != after_services[svc]:
            # Deep comparison
            diff[svc] = _deep_diff(before_services[svc], after_services[svc])
    
    # Filter out unchanged keys and timestamps
    cleaned_diff = {}
    for svc, changes in diff.items():
        if changes == "added" or changes == "removed":
            cleaned_diff[svc] = changes
        elif type(changes) == type({}):
            # Remove updatedAt and version fields if present
            cleaned = {}
            for k, v in changes.items():
                if k != "UpdatedAt" and k != "Version":
                    cleaned[k] = v
            if cleaned:
                cleaned_diff[svc] = cleaned
    
    if cleaned_diff:
        return {"changed": True, "msg": "Stack " + name + " updated", "data": {"stack_spec_diff": cleaned_diff}}
    
    return {"changed": False, "msg": "Stack " + name + " already present"}


def _parse_service_spec(output):
    # Minimal JSON parser for service inspect output (assumes single object)
    obj = {}
    content = output.strip()
    # Strip [ and ]
    if content.startswith("["):
        content = content[1:]
    if content.endswith("]"):
        content = content[:-1]
    # Simple key: value parser (handles basic structure)
    if '"Spec"' in content:
        spec_start = content.find('"Spec":')
        if spec_start != -1:
            brace_count = 0
            i = spec_start + len('"Spec":')
            while i < len(content) and brace_count >= 0:
                if content[i] == '{':
                    brace_count += 1
                elif content[i] == '}':
                    brace_count -= 1
                if brace_count == 0:
                    break
                i += 1
            spec_str = content[spec_start + len('"Spec":'):i+1]
            obj["Spec"] = _parse_dict(spec_str)
    return obj


def _parse_dict(s):
    s = s.strip()
    if not s.startswith('{') or not s.endswith('}'):
        return s
    s = s[1:-1]
    d = {}
    parts = []
    depth = 0
    current = ""
    for c in s:
        if c in '{[':
            depth += 1
        elif c in '}]':
            depth -= 1
        elif c == ',' and depth == 0:
            parts.append(current.strip())
            current = ""
            continue
        current += c
    if current.strip():
        parts.append(current.strip())
    for p in parts:
        if ':' in p:
            key, val = p.split(":", 1)
            key = key.strip().strip('"')
            val = val.strip()
            if val.startswith('{'):
                d[key] = _parse_dict(val)
            elif val.startswith('['):
                d[key] = val
            else:
                d[key] = val.strip('"')
    return d


def _deep_diff(a, b):
    if type(a) != type(b):
        return {"type": "changed", "from": str(type(a)), "to": str(type(b))}
    if type(a) == type({}):
        diff = {}
        all_keys = set(list(a.keys()) + list(b.keys()))
        for k in all_keys:
            if k not in a:
                diff[k] = "added"
            elif k not in b:
                diff[k] = "removed"
            else:
                sub = _deep_diff(a[k], b[k])
                if sub:
                    diff[k] = sub
        return diff if diff else {}
    elif type(a) == type([]):
        if len(a) != len(b):
            return {"length": "changed", "from": len(a), "to": len(b)}
        for i in range(len(a)):
            sub = _deep_diff(a[i], b[i])
            if sub:
                return {"index_" + str(i): sub}
        return {}
    else:
        if a != b:
            return {"from": str(a), "to": str(b)}
        return {}
