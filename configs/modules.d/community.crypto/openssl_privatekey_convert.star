def main(ctx, params):
    dest_path = params["dest_path"]
    src_path = params.get("src_path")
    src_content = params.get("src_content")
    format_opt = params["format"]
    src_passphrase = params.get("src_passphrase")
    dest_passphrase = params.get("dest_passphrase")
    backup = params.get("backup", False)
    mode = params.get("mode")
    owner = params.get("owner")
    group = params.get("group")

    # Validate source: exactly one of src_path or src_content
    if (src_path == None) == (src_content == None):
        fail("exactly one of src_path or src_content must be specified")

    # Ensure destination directory exists
    dir_path = dest_path
    if "/" in dest_path:
        parts = dest_path.rsplit("/", 1)
        dir_path = parts[0] if parts[0] != "" else "."
    if dir_path != "." and not ctx.file_exists(dir_path):
        fail("The directory " + dir_path + " does not exist or is not a directory")

    # Read source content
    if src_path != None:
        if not ctx.file_exists(src_path):
            fail("source file " + src_path + " does not exist")
        src_key_content = ctx.file_read(src_path)
    else:
        src_key_content = src_content

    # Determine current dest content if exists
    current_dest_content = None
    if ctx.file_exists(dest_path):
        current_dest_content = ctx.file_read(dest_path)

    # Default mode is 0600 if not specified
    final_mode = "0600"
    if mode != None:
        if isinstance(mode, str):
            if mode.startswith("0") and len(mode) <= 5:
                final_mode = mode
            elif len(mode) == 3 or len(mode) == 4:
                # Accept "644" or "0644"
                if mode[0] == "0":
                    final_mode = mode
                else:
                    final_mode = "0" + mode
            else:
                fail("invalid mode: " + mode)
        else:
            fail("mode must be a string")

    # Build openssl command arguments
    args = ["openssl", "pkey"]

    if src_path != None:
        args.extend(["-in", src_path])
    else:
        fail("src_content not supported in Starlark version; use src_path instead")

    if src_passphrase != None:
        args.extend(["-passin", "pass:" + src_passphrase])

    # Output format
    args.extend(["-outform", format_opt.upper()])

    # Check if conversion needed: use openssl to generate expected content
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        fail("openssl failed to convert key: " + res.stderr)

    new_content = res.stdout

    # Determine if change needed
    changed = current_dest_content == None or new_content != current_dest_content

    if ctx.check_mode:
        return {
            "changed": changed,
            "msg": "would convert private key" if changed else "already in desired state"
        }

    # Handle backup
    backup_file = None
    if backup and current_dest_content != None:
        # Generate timestamp-based backup name
        stat_info = ctx.stat(dest_path)
        ts = str(stat_info.get("mtime", "0")) if stat_info != None else "0"
        backup_file = dest_path + "." + ts + "~"
        ctx.file_write(backup_file, current_dest_content, mode=final_mode)

    # Write new content only if changed
    if changed:
        changed_write = ctx.file_write(dest_path, new_content, mode=final_mode)
        if changed_write == False:
            fail("failed to write destination file " + dest_path)

        # Set ownership if specified
        if owner != None or group != None:
            # Use chown (simplified: assume valid user/group names)
            chown_args = []
            if owner != None:
                chown_args.extend(["-u", owner])
            if group != None:
                chown_args.extend(["-g", group])
            chown_args.append(dest_path)
            chown_res = ctx.run(["chown"] + chown_args)
            if chown_res.rc != 0:
                fail("chown failed: " + chown_res.stderr)

    # Return result
    result = {
        "changed": changed,
        "msg": "converted private key" if changed else "already in desired state"
    }
    if backup_file != None:
        result["backup_file"] = backup_file

    return result
