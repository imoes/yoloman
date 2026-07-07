def main(ctx, params):
    # Extract parameters
    name = params.get("name")
    self_flag = params.get("self", False)

    # Build docker command base
    docker_cmd = ["docker"]

    # Add TLS-related flags if needed (only essential ones for node inspect)
    if params.get("tls", False):
        docker_cmd.append("--tls")

    if params.get("validate_certs", False):
        docker_cmd.append("--tls-verify")

    ca_path = params.get("ca_path")
    if ca_path != None:
        docker_cmd.extend(["--tlscacert", ca_path])

    client_cert = params.get("client_cert")
    if client_cert != None:
        docker_cmd.extend(["--tlscert", client_cert])

    client_key = params.get("client_key")
    if client_key != None:
        docker_cmd.extend(["--tlskey", client_key])

    # Handle docker_host
    docker_host = params.get("docker_host", "unix:///var/run/docker.sock")
    # Note: For TCP URLs with TLS, the SDK would convert to https; Starlark can't replicate that logic,
    # so we keep the original docker_host and let Docker CLI interpret it.

    # Build final command
    cmd = docker_cmd + ["node", "ls", "--format", "{{.ID}}\t{{.Hostname}}"]

    # Get list of nodes
    res = ctx.run(cmd)
    if res.rc != 0:
        fail("failed to list docker nodes: " + res.stderr)

    # Parse node list
    lines = res.stdout.strip().splitlines() if res.stdout.strip() else []
    node_map = {}  # id -> hostname
    hostnames = []
    for line in lines:
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) == 2:
            node_id, hostname = parts
            node_map[node_id] = hostname
            hostnames.append(hostname)

    # Determine target nodes
    target_ids = []

    if self_flag:
        # Get current node ID by inspecting self
        cmd = docker_cmd + ["node", "inspect", "self", "--format", "{{.ID}}"]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to inspect self: " + res.stderr)
        node_id = res.stdout.strip()
        if node_id:
            target_ids.append(node_id)
    else:
        if name == None or len(name) == 0:
            # All nodes: use IDs from node list
            target_ids = list(node_map.keys())
        else:
            # Normalize to list
            if type(name) != "list":
                name = [name]

            # For each provided name, resolve to node ID (prefer exact match first, then hostname lookup)
            for n in name:
                if n in node_map:
                    target_ids.append(n)
                elif n in node_map.values():
                    # Reverse lookup by hostname
                    for k, v in node_map.items():
                        if v == n:
                            target_ids.append(k)
                            break
                else:
                    # Try raw node ID if not found by hostname
                    target_ids.append(n)

    # Build final inspect results
    results = []
    for node_id in target_ids:
        cmd = docker_cmd + ["node", "inspect", node_id]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to inspect node " + node_id + ": " + res.stderr)

        # Docker CLI inspect outputs JSON; Starlark cannot parse JSON natively.
        # Since no json module is available and we cannot parse complex JSON in Starlark,
        # we return raw output as 'raw_inspect' and warn the limitation.
        # However, for correctness, we must produce structured data — Starlark cannot do so.
        # Therefore, we fail with a clear message indicating this module is not fully implementable.
        fail("community.docker.docker_node_info cannot be implemented in Starlark due to missing JSON parsing capability; docker node inspect outputs JSON, which Starlark cannot parse.")

    return {"changed": False, "msg": "Placeholder — module cannot run in Starlark.", "nodes": []}
