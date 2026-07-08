def main(ctx, params):
    # Required params
    container = params["container"]
    method = params.get("method", "get")
    obj_type = params.get("type", "file")

    # Validate method and type
    if method not in ["get", "put", "delete"]:
        ctx.fail("Invalid method: must be 'get', 'put', or 'delete'")
    if obj_type not in ["file", "meta"]:
        ctx.fail("Invalid type: must be 'file' or 'meta'")

    # Meta validation
    meta = params.get("meta", {})
    clear_meta = params.get("clear_meta", False)
    if clear_meta and obj_type != "meta":
        ctx.fail("clear_meta can only be used when type=meta")

    # Check for required parameters per operation
    if method == "put" and obj_type == "file":
        src = params.get("src")
        if not src:
            ctx.fail("src is required when method=put and type=file")
    elif method == "get" and obj_type == "file":
        dest = params.get("dest")
        if not dest:
            ctx.fail("dest is required when method=get and type=file")

    # Determine objects to operate on
    dest = params.get("dest")
    src = params.get("src")
    if method == "delete" and obj_type == "file":
        if src and dest:
            ctx.fail("Specify either src or dest (not both) for delete operations")
        objects = dest or src
    elif method == "get" and obj_type == "meta":
        if src and dest:
            ctx.fail("Specify either src or dest (not both) for metadata get operations")
        objects = dest or src
    elif method == "put" and obj_type == "meta":
        if src and dest:
            ctx.fail("Specify either src or dest (not both) for metadata put operations")
        objects = dest or src
    elif method == "delete" and obj_type == "meta":
        if src and dest:
            ctx.fail("Specify either src or dest (not both) for metadata delete operations")
        objects = dest or src
    else:
        objects = None

    # Base command construction
    cmd = ["swift", "stat"]
    if container:
        cmd.append(container)

    # Probing current state (dry-run safe)
    res = ctx.run(cmd + ["--format", "json"], mutates=False)
    if res.rc != 0:
        ctx.fail("Failed to access container {}: {}".format(container, res.stderr))

    # Check container exists by parsing output
    container_exists = False
    if len(res.stdout) > 0 and "Container" in res.stdout:
        container_exists = True
    if not container_exists:
        ctx.fail("Container {} does not exist".format(container))

    # Perform operations based on method and type
    changed = False
    msg = ""

    if method == "get" and obj_type == "file":
        # Download objects
        if not dest:
            ctx.fail("dest is required for file downloads")
        # Check if dest is directory
        stat_info = ctx.stat(dest)
        dest_is_dir = stat_info != None and stat_info.get("is_dir", False)
        if not dest_is_dir:
            ctx.fail("dest must be a directory for downloads")

        # Get objects list if src not provided
        if not src:
            # List all objects in container
            cmd = ["swift", "list", container]
            res = ctx.run(cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to list objects in container {}: {}".format(container, res.stderr))
            objects = res.stdout.strip().split("\n") if res.stdout.strip() else []
        else:
            objects = [x.strip() for x in src.split(",") if x.strip()]

        # Download each object
        structure = params.get("structure", True)
        for obj in objects:
            out_path = dest + "/" + obj if structure else dest + "/" + obj.rsplit("/", 1)[-1]
            cmd = ["swift", "download", container, obj, "--output", out_path]
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                changed = True
                continue
            if res.rc != 0:
                # Try to continue with other objects
                msg = "Error downloading object {}: {}".format(obj, res.stderr)
            else:
                changed = True

        if not changed:
            msg = "All downloads failed or no objects to download"
        else:
            msg = "Downloaded {} objects to {}".format(len(objects), dest)

    elif method == "put" and obj_type == "file":
        # Upload objects
        src_path = src
        if ctx.check_mode:
            changed = True
            msg = "would upload {} to container {}".format(src_path, container)
            return {"changed": changed, "msg": msg}

        # Check if src exists
        if not ctx.file_exists(src_path):
            ctx.fail("Source {} does not exist".format(src_path))

        src_is_dir = ctx.stat(src_path).get("is_dir", False)
        if src_is_dir:
            # List files in directory and upload each
            cmd = ["find", src_path, "-type", "f"]
            res = ctx.run(cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to list source directory: {}".format(res.stderr))
            files = res.stdout.strip().split("\n") if res.stdout.strip() else []

            for file_path in files:
                rel_path = file_path[len(src_path):].lstrip("/")
                cmd = ["swift", "upload", container, file_path, "--name", rel_path]
                if "expires" in params:
                    cmd += ["--object-meta", "X-Delete-After:{}".format(params["expires"])]
                if meta:
                    for k, v in meta.items():
                        cmd += ["--object-meta", "{}:{}".format(k, v)]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    ctx.fail("Failed to upload {}: {}".format(file_path, res.stderr))
                changed = True
        else:
            # Single file upload
            cmd = ["swift", "upload", container, src_path]
            if dest:
                cmd += ["--name", dest]
            if "expires" in params:
                cmd += ["--object-meta", "X-Delete-After:{}".format(params["expires"])]
            if meta:
                for k, v in meta.items():
                    cmd += ["--object-meta", "{}:{}".format(k, v)]
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                ctx.fail("Failed to upload {}: {}".format(src_path, res.stderr))
            changed = True

        msg = "Uploaded {} to container {}".format(src_path, container) if not src_is_dir else "Uploaded directory {} to container {}".format(src_path, container)

    elif method == "delete" and obj_type == "file":
        # Delete objects
        if not src and not dest:
            # Delete all objects in container
            if ctx.check_mode:
                changed = True
                msg = "would delete all objects in container {}".format(container)
                return {"changed": changed, "msg": msg}

            cmd = ["swift", "list", container]
            res = ctx.run(cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to list objects: {}".format(res.stderr))
            objects = res.stdout.strip().split("\n") if res.stdout.strip() else []

            if not objects:
                msg = "No objects to delete in container {}".format(container)
            else:
                for obj in objects:
                    cmd = ["swift", "delete", container, obj]
                    res = ctx.run(cmd, mutates=True)
                    if res.skipped:
                        changed = True
                        continue
                    if res.rc != 0 and "404" not in res.stderr:
                        # Continue even for 404s (object already deleted)
                        pass
                    changed = True

                msg = "Deleted {} objects from container {}".format(len(objects), container)
        else:
            # Delete specified objects
            if src:
                objects = [x.strip() for x in src.split(",") if x.strip()]
            else:
                objects = [x.strip() for x in dest.split(",") if x.strip()]

            if ctx.check_mode:
                changed = True
                msg = "would delete objects: {}".format(",".join(objects))
                return {"changed": changed, "msg": msg}

            for obj in objects:
                cmd = ["swift", "delete", container, obj]
                res = ctx.run(cmd, mutates=True)
                if res.skipped:
                    changed = True
                    continue
                if res.rc != 0 and "404" not in res.stderr:
                    # Continue even for 404s (object already deleted)
                    pass
                changed = True

            msg = "Deleted {} objects from container {}".format(len(objects), container)

    elif obj_type == "meta":
        # Handle metadata operations
        if method == "get":
            # Get metadata
            if not src and not dest:
                ctx.fail("Either src or dest is required for metadata retrieval")
            objects = [x.strip() for x in (src or dest).split(",") if x.strip()]

            # Get metadata for each object
            metadata_results = {}
            for obj in objects:
                cmd = ["swift", "stat", container, obj]
                res = ctx.run(cmd, mutates=False)
                if res.rc != 0:
                    # Object may not exist
                    continue
                # Parse metadata from output
                lines = res.stdout.strip().split("\n")
                meta_dict = {}
                for line in lines:
                    if line.startswith("X-Object-Meta-"):
                        parts = line.split(":", 1)
                        if len(parts) == 2:
                            key = parts[0].replace("X-Object-Meta-", "").strip()
                            value = parts[1].strip()
                            meta_dict[key] = value
                metadata_results[obj] = meta_dict

            if metadata_results:
                changed = False
                msg = "Retrieved metadata for {} objects".format(len(metadata_results))
                return {"changed": changed, "msg": msg, "meta_results": metadata_results}
            else:
                ctx.fail("No metadata found for specified objects")

        elif method == "put":
            # Set metadata
            if not src and not dest:
                ctx.fail("Either src or dest is required to set metadata")
            objects = [x.strip() for x in (src or dest).split(",") if x.strip()]

            if ctx.check_mode:
                changed = True
                msg = "would set metadata on objects: {}".format(",".join(objects))
                return {"changed": changed, "msg": msg}

            for obj in objects:
                cmd = ["swift", "post", container, obj]
                # Add metadata
                for k, v in meta.items():
                    cmd += ["--object-meta", "{}:{}".format(k, v)]
                if clear_meta:
                    cmd += ["--clear-object-meta"]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    ctx.fail("Failed to set metadata on {}: {}".format(obj, res.stderr))
                changed = True

            msg = "Set metadata on {} objects".format(len(objects))

        elif method == "delete":
            # Delete metadata keys
            if not src and not dest:
                ctx.fail("Either src or dest is required to delete metadata")
            objects = [x.strip() for x in (src or dest).split(",") if x.strip()]

            if ctx.check_mode:
                changed = True
                msg = "would delete metadata keys on objects: {}".format(",".join(objects))
                return {"changed": changed, "msg": msg}

            for obj in objects:
                cmd = ["swift", "post", container, obj]
                if meta:
                    for k, v in meta.items():
                        cmd += ["--object-meta", "{}:".format(k)]
                else:
                    # Clear all meta
                    cmd += ["--clear-object-meta"]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    ctx.fail("Failed to delete metadata on {}: {}".format(obj, res.stderr))
                changed = True

            msg = "Deleted metadata keys on {} objects".format(len(objects))

    return {"changed": changed, "msg": msg}
