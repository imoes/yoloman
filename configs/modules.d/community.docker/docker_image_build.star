def main(ctx, params):
    # Extract parameters
    name = params["name"]
    tag = params.get("tag", "latest")
    path = params["path"]
    dockerfile = params.get("dockerfile")
    cache_from = params.get("cache_from", [])
    pull = params.get("pull", False)
    network = params.get("network")
    nocache = params.get("nocache", False)
    etc_hosts = params.get("etc_hosts")
    args = params.get("args")
    target = params.get("target")
    platform = params.get("platform")
    shm_size = params.get("shm_size")
    labels = params.get("labels")
    rebuild = params.get("rebuild", "never")
    cli_context = params.get("cli_context")
    docker_cli = params.get("docker_cli", "docker")

    # Basic validation
    if not path:
        fail("path must be provided")

    # Check if path is a directory
    if not ctx.file_exists(path):
        fail('"' + path + '" is not an existing directory')
    stat_result = ctx.stat(path)
    if not stat_result["is_dir"]:
        fail('"' + path + '" is not a directory')

    # Check dockerfile if specified
    if dockerfile:
        full_dockerfile = path + "/" + dockerfile
        if not ctx.file_exists(full_dockerfile):
            fail('"' + full_dockerfile + '" is not an existing file')

    # Check for buildx plugin availability via CLI
    res = ctx.run([docker_cli, "plugin", "ls", "--format", "{{.Name}}"], mutates=False)
    if res.rc != 0:
        fail("failed to list docker plugins: " + res.stderr)
    plugins = res.stdout.strip().split("\n")
    if "buildx" not in plugins:
        fail("Docker CLI does not have the buildx plugin installed")

    # If name contains a tag, it takes precedence
    if ":" in name:
        parts = name.split(":", 1)
        name = parts[0]
        tag = parts[1]

    # Determine desired state: rebuild?
    # We simulate image existence check by trying to inspect image
    # Note: We use docker image inspect to check existence
    image_name_tag = name + ":" + tag
    inspect_res = ctx.run([docker_cli, "image", "inspect", image_name_tag], mutates=False)
    image_exists = inspect_res.rc == 0

    # Build args list
    args_list = [docker_cli, "buildx", "build", "--progress", "plain"]
    args_list.extend(["--tag", image_name_tag])

    if dockerfile:
        args_list.extend(["--file", full_dockerfile])
    if cache_from:
        for cache_img in cache_from:
            args_list.extend(["--cache-from", cache_img])
    if pull:
        args_list.append("--pull")
    if network:
        args_list.extend(["--network", network])
    if nocache:
        args_list.append("--no-cache")
    if etc_hosts:
        for k, v in sorted(etc_hosts.items()):
            args_list.extend(["--add-host", str(k) + ":" + str(v)])
    if args:
        for k, v in sorted(args.items()):
            args_list.extend(["--build-arg", str(k) + "=" + str(v)])
    if target:
        args_list.extend(["--target", target])
    if platform:
        args_list.extend(["--platform", platform])
    if shm_size:
        args_list.extend(["--shm-size", str(shm_size)])
    if labels:
        for k, v in sorted(labels.items()):
            args_list.extend(["--label", str(k) + "=" + str(v)])

    args_list.extend(["--", path])

    # Determine if change is needed
    if image_exists and rebuild == "never":
        return {"changed": False, "msg": "Image already exists and rebuild=never"}

    # In check_mode: predict change
    if ctx.check_mode:
        if not image_exists or rebuild == "always":
            return {"changed": True, "msg": "would build image " + image_name_tag}
        return {"changed": False, "msg": "image already exists and rebuild=never"}

    # Perform the build
    res = ctx.run(args_list, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would build image " + image_name_tag}
    if res.rc != 0:
        fail("Building " + image_name_tag + " failed: " + res.stderr)

    # Get final image state
    inspect_res = ctx.run([docker_cli, "image", "inspect", image_name_tag], mutates=False)
    image_data = {}
    if inspect_res.rc == 0:
        # We cannot parse JSON without the json module, so return basic success
        image_data = {"Name": image_name_tag}

    return {"changed": True, "msg": "built image " + image_name_tag, "data": image_data}
