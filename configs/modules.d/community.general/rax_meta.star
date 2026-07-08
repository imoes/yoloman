def main(ctx, params):
    # Required one of: address, id, name
    address = params.get("address")
    server_id = params.get("id")
    name = params.get("name")
    meta = params.get("meta", {})

    if [address != None, server_id != None, name != None].count(True) != 1:
        fail("One of 'address', 'id', or 'name' is required")

    # Build the rax CLI command
    # We'll use rax CLI (rax servers list, rax servers metadata set) via ctx.run
    # rax CLI must be installed and configured in the environment

    # Step 1: Find server ID based on provided criteria
    found_id = None
    if name != None:
        # Use rax servers list --name to find exact match
        res = ctx.run(["rax", "servers", "list", "--name", "^" + name + "$", "--format", "value"], mutates=False)
        if res.rc != 0:
            fail("Failed to list servers: " + res.stderr)
        lines = res.stdout.strip().split("\n") if res.stdout.strip() else []
        # Filter for exact name match (regex match is not perfect via CLI, fallback needed)
        # rax CLI's --name uses regex, so we double-check exact match
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == name:
                if found_id != None:
                    fail("Multiple servers found matching name: " + name)
                found_id = parts[0]
        if found_id == None:
            fail("No server found matching name: " + name)
    elif address != None:
        # List all servers and grep for IP in networks
        res = ctx.run(["rax", "servers", "list", "--format", "value"], mutates=False)
        if res.rc != 0:
            fail("Failed to list servers: " + res.stderr)
        lines = res.stdout.strip().split("\n") if res.stdout.strip() else []
        for line in lines:
            parts = line.split()
            if len(parts) < 2:
                continue
            srv_id = parts[0]
            srv_name = parts[1]
            # Get server networks
            net_res = ctx.run(["rax", "servers", "show", srv_id, "--format", "value"], mutates=False)
            if net_res.rc != 0:
                continue
            # Look for address in networks output
            # rax servers show output has network info; grep is not available, use find/scan
            networks = net_res.stdout
            if networks.find(address) != -1:
                if found_id != None:
                    fail("Multiple servers found matching address: " + address)
                found_id = srv_id
        if found_id == None:
            fail("No server found with address: " + address)
    else:  # server_id != None
        # Verify server exists
        res = ctx.run(["rax", "servers", "show", server_id, "--format", "value"], mutates=False)
        if res.rc != 0:
            fail("Failed to find server with ID: " + server_id)
        found_id = server_id

    # Step 2: Get current metadata
    curr_res = ctx.run(["rax", "servers", "meta", "show", found_id, "--format", "value"], mutates=False)
    if curr_res.rc != 0:
        fail("Failed to get current metadata: " + curr_res.stderr)

    # Parse current metadata (key=value lines)
    current_meta = {}
    for line in curr_res.stdout.strip().split("\n"):
        line = line.strip()
        if line == "":
            continue
        if "=" not in line:
            continue
        idx = line.find("=")
        key = line[:idx].strip()
        val = line[idx+1:].strip()
        current_meta[key] = val

    # Step 3: Normalize meta values to strings (as Python implementation does)
    normalized_meta = {}
    for k, v in meta.items():
        if type(v) == "list":
            normalized_meta[k] = ",".join([str(x) for x in v])
        elif type(v) == "dict":
            # JSON dumps not available; use simple format for small dicts
            # We'll just fail for dicts to avoid complex JSON emulation
            fail("Dict values for meta are not supported in Starlark (use string representations)")
        else:
            normalized_meta[k] = str(v)

    # Step 4: Compare and compute changes
    if normalized_meta == current_meta:
        return {"changed": False, "msg": "Metadata already up to date"}

    # Step 5: Apply changes (diff: remove old keys not in new meta, set new keys)
    # First, remove keys not in new meta
    to_remove = [k for k in current_meta.keys() if k not in normalized_meta]
    to_set = {k: v for k, v in normalized_meta.items() if current_meta.get(k) != v}

    if len(to_remove) > 0:
        # rax servers meta delete key1 key2 ...
        delete_cmd = ["rax", "servers", "meta", "delete", found_id] + to_remove
        del_res = ctx.run(delete_cmd, mutates=True)
        if del_res.rc != 0:
            fail("Failed to delete keys: " + del_res.stderr)

    # Then set new/updated keys
    if len(to_set) > 0:
        # rax servers meta set key1 value1 key2 value2 ...
        set_args = ["rax", "servers", "meta", "set", found_id]
        for k, v in to_set.items():
            set_args.extend([k, v])
        set_res = ctx.run(set_args, mutates=True)
        if set_res.rc != 0:
            fail("Failed to set metadata: " + set_res.stderr)

    # Step 6: Get final metadata for response
    final_res = ctx.run(["rax", "servers", "meta", "show", found_id, "--format", "value"], mutates=False)
    if final_res.rc != 0:
        fail("Failed to get final metadata: " + final_res.stderr)

    # Parse final metadata
    final_meta = {}
    for line in final_res.stdout.strip().split("\n"):
        line = line.strip()
        if line == "" or "=" not in line:
            continue
        idx = line.find("=")
        key = line[:idx].strip()
        val = line[idx+1:].strip()
        final_meta[key] = val

    return {"changed": True, "msg": "Metadata updated", "meta": final_meta}
