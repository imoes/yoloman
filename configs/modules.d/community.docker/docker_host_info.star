def main(ctx, params):
    # Extract parameters
    containers = params.get("containers", False)
    containers_all = params.get("containers_all", False)
    containers_filters = params.get("containers_filters")
    images = params.get("images", False)
    images_filters = params.get("images_filters")
    networks = params.get("networks", False)
    networks_filters = params.get("networks_filters")
    volumes = params.get("volumes", False)
    volumes_filters = params.get("volumes_filters")
    disk_usage = params.get("disk_usage", False)
    verbose_output = params.get("verbose_output", False)
    docker_host = params.get("docker_host", "unix:///var/run/docker.sock")
    api_version = params.get("api_version", "auto")
    timeout = params.get("timeout", 60)
    tls = params.get("tls", False)
    validate_certs = params.get("validate_certs", False)
    ca_path = params.get("ca_path")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")

    # Build docker CLI arguments
    base_args = ["docker"]

    # TLS/SSL options
    if validate_certs:
        base_args.extend(["--tlsverify"])
    elif tls:
        base_args.extend(["--tls"])

    # Certificates
    if ca_path:
        base_args.extend(["--tlscacert", ca_path])
    if client_cert:
        base_args.extend(["--tlscert", client_cert])
    if client_key:
        base_args.extend(["--tlskey", client_key])

    # Host
    base_args.extend(["--host", docker_host])

    results = {
        "changed": False,
        "host_info": {},
        "can_talk_to_docker": False
    }

    # Check if can talk to docker and get basic host info
    res = ctx.run(base_args + ["info", "--format", "{{json .}}"], mutates=False)
    if res.rc != 0:
        fail("Cannot talk to Docker daemon: " + res.stderr)
    results["can_talk_to_docker"] = True

    # Parse docker info output (simple JSON extraction)
    info_str = res.stdout.strip()
    if info_str.startswith("{") and info_str.endswith("}"):
        # Remove outer braces and parse key-value pairs
        inner = info_str[1:-1]
        results["host_info"] = _parse_docker_info(inner)
    else:
        results["host_info"] = {"raw": info_str}

    # Collect containers list if requested
    if containers:
        args = base_args + ["container", "ls", "--format", "{{json .}}"]
        if containers_all:
            args.append("-a")
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("Failed to list containers: " + res.stderr)
        results["containers"] = _parse_container_lines(res.stdout, verbose_output)

    # Collect images list if requested
    if images:
        args = base_args + ["image", "ls", "--format", "{{json .}}"]
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("Failed to list images: " + res.stderr)
        results["images"] = _parse_image_lines(res.stdout, verbose_output)

    # Collect networks list if requested
    if networks:
        args = base_args + ["network", "ls", "--format", "{{json .}}"]
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("Failed to list networks: " + res.stderr)
        results["networks"] = _parse_network_lines(res.stdout, verbose_output)

    # Collect volumes list if requested
    if volumes:
        args = base_args + ["volume", "ls", "--format", "{{json .}}"]
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("Failed to list volumes: " + res.stderr)
        results["volumes"] = _parse_volume_lines(res.stdout, verbose_output)

    # Disk usage if requested
    if disk_usage:
        args = base_args + ["system", "df", "--format", "{{json .}}"]
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("Failed to get disk usage: " + res.stderr)
        results["disk_usage"] = _parse_disk_usage(res.stdout, verbose_output)

    return {
        "changed": False,
        "msg": "Retrieved docker host information",
        "data": results
    }


def _parse_docker_info(s):
    result = {}
    # Simplified parsing: split by comma and then by colon
    pairs = s.split(",")
    for pair in pairs:
        pair = pair.strip()
        if ":" in pair:
            idx = pair.find(":")
            k = pair[:idx].strip().strip('"')
            v = pair[idx+1:].strip().strip('"')
            result[k] = v
    return result


def _parse_container_lines(output, verbose):
    lines = output.strip().split("\n")
    result = []
    for line in lines:
        if not line.strip():
            continue
        if verbose:
            result.append(_parse_json_line(line))
        else:
            d = _parse_json_line(line)
            result.append({
                "Id": d.get("ID", ""),
                "Image": d.get("Image", ""),
                "Command": d.get("Command", ""),
                "Created": d.get("Created", ""),
                "Status": d.get("Status", ""),
                "Ports": d.get("Ports", ""),
                "Names": d.get("Names", "")
            })
    return result


def _parse_image_lines(output, verbose):
    lines = output.strip().split("\n")
    result = []
    for line in lines:
        if not line.strip():
            continue
        if verbose:
            result.append(_parse_json_line(line))
        else:
            d = _parse_json_line(line)
            repo = d.get("Repository", "")
            tag = d.get("Tag", "")
            result.append({
                "Id": d.get("ID", ""),
                "RepoTags": repo + ":" + tag if tag else repo,
                "Created": d.get("Created", ""),
                "Size": d.get("Size", "")
            })
    return result


def _parse_network_lines(output, verbose):
    lines = output.strip().split("\n")
    result = []
    for line in lines:
        if not line.strip():
            continue
        if verbose:
            result.append(_parse_json_line(line))
        else:
            d = _parse_json_line(line)
            result.append({
                "Id": d.get("ID", ""),
                "Driver": d.get("Driver", ""),
                "Name": d.get("Name", ""),
                "Scope": d.get("Scope", "")
            })
    return result


def _parse_volume_lines(output, verbose):
    lines = output.strip().split("\n")
    result = []
    for line in lines:
        if not line.strip():
            continue
        if verbose:
            result.append(_parse_json_line(line))
        else:
            d = _parse_json_line(line)
            result.append({
                "Driver": d.get("Driver", ""),
                "Name": d.get("Name", "")
            })
    return result


def _parse_disk_usage(output, verbose):
    if verbose:
        return {"raw": output}
    # Parse summary line
    lines = output.strip().split("\n")
    for line in lines:
        if "Images" in line or "Containers" in line or "Local Volumes" in line:
            parts = line.strip().split()
            if parts and parts[-1].isdigit():
                return {"LayersSize": int(parts[-1])}
    return {"LayersSize": 0}


def _parse_json_line(line):
    # Very basic JSON key-value parser for Starlark
    line = line.strip()
    if not line.startswith("{") or not line.endswith("}"):
        return {}
    inner = line[1:-1]
    result = {}
    # Split by comma, but be cautious of nested structures
    parts = []
    depth = 0
    current = ""
    for ch in inner:
        if ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current.strip())
    for part in parts:
        if ":" in part:
            idx = part.find(":")
            k = part[:idx].strip().strip('"')
            v = part[idx+1:].strip().strip('"')
            result[k] = v
    return result
