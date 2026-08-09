def main(ctx, params):
    # Required parameters
    container = params["container"]
    container_path = params["container_path"]
    
    # Mutually exclusive source: content or path
    content = params.get("content")
    path = params.get("path")
    if content == None and path == None:
        ctx.fail("One of 'content' and 'path' must be supplied")
    if content != None and path != None:
        ctx.fail("Parameters 'content' and 'path' are mutually exclusive")
    
    # Validate container_path is absolute
    if not container_path.startswith("/"):
        container_path = "/" + container_path
    # Normalize (remove double slashes, resolve . and ..) — simple implementation
    parts = []
    for p in container_path.split("/"):
        if p == "" or p == ".":
            continue
        if p == "..":
            if len(parts) > 0:
                parts.pop()
        else:
            parts.append(p)
    container_path = "/" + "/".join(parts)

    # Options
    follow = params.get("follow", False)
    local_follow = params.get("local_follow", True)
    force = params.get("force")
    mode = params.get("mode")
    owner_id = params.get("owner_id")
    group_id = params.get("group_id")
    content_is_b64 = params.get("content_is_b64", False)
    
    # Content handling (base64 decode if needed)
    if content != None:
        if content_is_b64:
            ctx.fail("Base64 decoding of content is not supported in Starlark runtime")
    else:
        # Read local file if path provided
        content_bytes = ctx.file_read(path)

    # Determine owner_id and group_id if missing
    # Only possible if container is running and has /bin/sh + id command
    if owner_id == None or group_id == None:
        # Try to get user/group IDs via 'id' command in container
        res = ctx.run(["docker", "exec", container, "/bin/sh", "-c", "id -u && id -g"], mutates=False)
        if res.rc == 0:
            lines = res.stdout.strip().split("\n")
            if len(lines) >= 2:
                owner_id = int(lines[0])
                group_id = int(lines[1])
            else:
                ctx.fail("Could not determine user/group IDs from container")
        else:
            ctx.fail("Cannot determine user/group IDs. Container may not be running, or missing /bin/sh or 'id' command. Please provide 'owner_id' and 'group_id' explicitly")

    # Check idempotency (if not forced)
    changed = True
    if force == False:
        # If destination exists, do not overwrite
        res = ctx.run(["docker", "exec", container, "test", "-e", container_path], mutates=False)
        if res.rc == 0:
            changed = False
    elif force != True:
        # force == None: try idempotent copy
        res = ctx.run(["docker", "exec", container, "stat", "-c", "%F %s %u %g %a", container_path], mutates=False)
        if res.rc == 0:
            changed = False

    if ctx.check_mode:
        if changed:
            return {"changed": True, "msg": "Would copy file into container"}
        else:
            return {"changed": False, "msg": "File already in container (no change)"}

    # Perform the copy
    if content != None:
        ctx.fail("Copying from 'content' option is not supported in this Starlark translation because it requires Docker SDK internals not available via CLI")
    else:
        ctx.fail("Copying from 'path' option is not supported in this Starlark translation because 'docker cp' requires the file to be on the Docker host, not the managed node")

    return {"changed": changed, "msg": "Copy operation completed", "container_path": container_path}
