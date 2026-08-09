def main(ctx, params):
    paths = params["path"]
    format_opt = params.get("format", "gz")
    dest = params.get("dest")
    exclude_path = params.get("exclude_path", [])
    exclusion_patterns = params.get("exclusion_patterns", [])
    force_archive = params.get("force_archive", False)
    remove = params.get("remove", False)
    mode = params.get("mode")
    owner = params.get("owner")
    group = params.get("group")
    seuser = params.get("seuser")
    serole = params.get("serole")
    setype = params.get("setype")
    selevel = params.get("selevel")
    unsafe_writes = params.get("unsafe_writes", False)
    attributes = params.get("attributes")

    # Validate format
    if format_opt not in ["gz", "bz2", "tar", "xz", "zip"]:
        fail("Invalid format '%s'. Supported formats: gz, bz2, tar, xz, zip" % format_opt)

    # Check if any path is missing and expand globs
    expanded_paths = []
    for p in paths:
        if not ctx.file_exists(p):
            fail("Path does not exist: %s" % p)
        if "*" in p or "?" in p:
            # glob expansion not directly available in Starlark; fail if used
            fail("Glob patterns are not supported in this Starlark translation.")
        expanded_paths.append(p)

    # Determine if archiving is required
    must_archive = force_archive or len(expanded_paths) > 1
    if len(expanded_paths) == 1 and not must_archive and format_opt in ["tar", "zip"]:
        must_archive = ctx.stat(expanded_paths[0]).get("is_dir", False)

    # Determine destination if not provided
    if dest == None:
        if not must_archive:
            dest = expanded_paths[0] + "." + format_opt
        else:
            fail("dest is required when archiving multiple files or directories")

    # Create archive (only zip and tar-like formats supported via external tools)
    # For Starlark, we call system tools (tar, zip) instead of Python libraries
    # tar command handles gzip/bzip2/xz via options
    # zip command handles zip format
    cmd = None
    if format_opt == "zip":
        cmd = ["zip", "-r", dest] + expanded_paths
    elif format_opt in ["gz", "bz2", "xz"]:
        # tar handles these compression types
        if format_opt == "gz":
            cmd = ["tar", "-czf", dest] + expanded_paths
        elif format_opt == "bz2":
            cmd = ["tar", "-cjf", dest] + expanded_paths
        elif format_opt == "xz":
            cmd = ["tar", "-cJf", dest] + expanded_paths
    elif format_opt == "tar":
        cmd = ["tar", "-cf", dest] + expanded_paths

    if cmd == None:
        fail("Unsupported format for external tool: " + format_opt)

    # Handle check_mode
    if ctx.check_mode:
        # If dest exists and is an archive, assume unchanged
        # For simplicity, check if dest exists and assume it's unchanged if format matches
        stat = ctx.stat(dest)
        if stat != None and stat.get("exists", False):
            return {"changed": False, "msg": "Archive already exists in check mode"}
        return {"changed": True, "msg": "Would create archive at %s" % dest}

    # Run the archive command
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("Failed to create archive: " + res.stderr)

    # Update file attributes (owner, group, mode, SELinux context, attributes)
    file_args = {"path": dest}
    if mode != None:
        file_args["mode"] = mode
    if owner != None:
        file_args["owner"] = owner
    if group != None:
        file_args["group"] = group
    if seuser != None:
        file_args["seuser"] = seuser
    if serole != None:
        file_args["serole"] = serole
    if setype != None:
        file_args["setype"] = setype
    if selevel != None:
        file_args["selevel"] = selevel
    if attributes != None:
        file_args["attr"] = attributes

    # Apply file attributes using chown and chmod
    if owner != None or group != None:
        chown_cmd = ["chown"]
        if owner != None and group != None:
            chown_cmd.append(owner + ":" + group)
        elif owner != None:
            chown_cmd.append(owner)
        else:
            chown_cmd.append(":" + group)
        chown_cmd.append(dest)
        ctx.run(chown_cmd, mutates=True)

    if mode != None:
        chmod_cmd = ["chmod", mode, dest]
        ctx.run(chmod_cmd, mutates=True)

    # Apply SELinux context if any SELinux fields are provided
    if seuser != None or serole != None or setype != None or selevel != None:
        secmd = ["chcon"]
        if seuser != None:
            secmd.extend(["-u", seuser])
        if serole != None:
            secmd.extend(["-r", serole])
        if setype != None:
            secmd.extend(["-t", setype])
        if selevel != None:
            secmd.extend(["-l", selevel])
        secmd.append(dest)
        ctx.run(secmd, mutates=True)

    # Apply file attributes (chattr) if provided
    if attributes != None:
        attr_cmd = ["chattr"]
        # Interpret attributes string: assume '=' operator if no operator prefix
        attr_str = attributes
        if not (attr_str.startswith("+") or attr_str.startswith("-") or attr_str.startswith("=")):
            attr_str = "=" + attr_str
        attr_cmd.append(attr_str)
        attr_cmd.append(dest)
        ctx.run(attr_cmd, mutates=True)

    # Remove source files if requested
    if remove:
        for p in expanded_paths:
            if ctx.file_exists(p):
                if ctx.stat(p).get("is_dir", False):
                    ctx.run(["rm", "-rf", p], mutates=True)
                else:
                    ctx.run(["rm", "-f", p], mutates=True)

    return {"changed": True, "msg": "Archive created at %s" % dest}
