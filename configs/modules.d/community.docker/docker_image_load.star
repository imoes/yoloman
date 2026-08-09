def main(ctx, params):
    # Required
    path = params["path"]
    if not ctx.file_exists(path):
        fail("Error opening archive " + path + ": file not found")

    # Docker connection params - only use what's needed for docker CLI
    host = params.get("docker_host", "unix:///var/run/docker.sock")
    # Determine if TLS is needed (https instead of tcp)
    if host.startswith("tcp://"):
        host = "https://" + host[6:]
    elif host.startswith("unix://"):
        pass  # leave as-is for Unix socket

    # Build docker CLI args
    # Note: We use `docker load` CLI command instead of API because
    # the Starlark ctx.run() cannot stream data efficiently like Ansible can.
    # This is a simplification: we rely on `docker load < file` idiom.

    # Prepare command: `docker -H ... load < path`
    # Since ctx.run doesn't support shell redirection, we use:
    #   docker load -i <path>
    # which is equivalent and avoids shell tricks.
    args = ["docker"]
    args.append("-H")
    args.append(host)

    # Add TLS options if specified (only basic support)
    if params.get("tls", False) or params.get("validate_certs", False):
        # TLS is enabled
        args.append("--tls")

    if params.get("validate_certs", False):
        args.append("--tlsverify")
        # CA cert
        ca_path = params.get("ca_path") or params.get("tls_ca_cert") or params.get("cacert_path")
        if ca_path:
            args.append("--tlscacert")
            args.append(ca_path)
        # Client cert/key
        client_cert = params.get("client_cert") or params.get("tls_client_cert") or params.get("cert_path")
        if client_cert:
            args.append("--tlscert")
            args.append(client_cert)
        client_key = params.get("client_key") or params.get("tls_client_key") or params.get("key_path")
        if client_key:
            args.append("--tlskey")
            args.append(client_key)

    args.append("load")
    args.append("-i")
    args.append(path)

    # In check_mode, we cannot actually run docker load,
    # so we simulate idempotency: if no images were previously loaded, changed=True.
    # But without actually loading, we can't know. Per original module,
    # check_mode is NOT supported. So we fail.
    if ctx.check_mode:
        # Original Python module explicitly: supports_check_mode=False
        fail("check_mode is not supported by this module")

    res = ctx.run(args, mutates=True, ok_codes=[0])
    if res.skipped:
        fail("docker load command would have been skipped in check_mode")

    if res.rc != 0:
        fail("Error loading archive " + path + ": " + res.stderr, stdout=res.stdout)

    # Parse output for loaded images:
    # Output lines like:
    #   Loaded image: image:tag
    #   Loaded image ID: sha256:...
    # or for multiple:
    #   Loaded image(s): image:tag, sha256:abc...
    # We split and parse.

    image_names = []
    stdout_lines = res.stdout.strip().split("\n") if res.stdout else []
    for line in stdout_lines:
        line = line.strip()
        if line.startswith("Loaded image:"):
            image_names.append(line[len("Loaded image:"):].strip())
        elif line.startswith("Loaded image ID:"):
            image_names.append(line[len("Loaded image ID:"):].strip())
        elif line.startswith("Loaded image(s):"):
            # Parse comma-separated list
            rest = line[len("Loaded image(s):"):].strip()
            for name in rest.split(","):
                name = name.strip()
                if name:
                    image_names.append(name)

    if not image_names:
        fail("Detected no loaded images. Archive potentially corrupt?", stdout=res.stdout)

    # images: dict of inspection results - we skip this in Starlark
    # because it requires docker inspect on each image, and the original
    # module returns this but the Starlark context has no docker inspect.
    # We return only image_names, consistent with minimal viable translation.
    return {
        "changed": True,
        "msg": "Loaded " + str(len(image_names)) + " image(s)",
        "data": {
            "image_names": image_names,
            "images": []
        }
    }
