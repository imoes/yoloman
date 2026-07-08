def main(ctx, params):
    path = params["path"]
    backup = params.get("backup", False)
    values = params["values"]
    kwriteconfig_path = params.get("kwriteconfig_path")
    unsafe_writes = params.get("unsafe_writes", False)

    # Discover kwriteconfig binary if not provided
    kwriteconfig = None
    if kwriteconfig_path != None:
        kwriteconfig = kwriteconfig_path
    else:
        for prog in ["kwriteconfig5", "kwriteconfig", "kwriteconfig4"]:
            res = ctx.run([prog], ok_codes=[0, 1, 127])
            if res.rc == 0:
                kwriteconfig = prog
                break

    if kwriteconfig == None:
        fail("kwriteconfig is not installed")

    # Check mode: predict change without writing
    if ctx.check_mode:
        changed = True
        return {"changed": changed, "msg": "would update config"}

    # Non-check_mode: perform actual work
    tmpfile = "/tmp/kdeconfig_tmp_" + str(hash(path))
    if ctx.file_exists(tmpfile):
        ctx.run(["rm", "-f", tmpfile])

    # Copy existing file to temp if it exists
    if ctx.file_exists(path):
        current = ctx.file_read(path)
        ctx.file_write(tmpfile, current)
    else:
        ctx.file_write(tmpfile, "")

    # Apply each value using kwriteconfig
    for entry in values:
        groups = entry.get("groups")
        if groups == None:
            groups = [entry["group"]]
        key = entry["key"]
        value = entry.get("bool_value")
        if value == None:
            value = entry.get("value")

        # Build kwriteconfig command
        args = [kwriteconfig, "--file", tmpfile, "--key", key]
        for group in groups:
            args.extend(["--group", group])
        if type(value) == "bool":
            args.extend(["--type", "bool"])
            if value:
                args.append("true")
            else:
                args.append("false")
        else:
            args.append(str(value))

        res = ctx.run(args, mutates=True)
        if res.rc != 0:
            fail("kwriteconfig failed: " + res.stderr)

    # Read modified temp file
    new_content = ctx.file_read(tmpfile)

    # Compare with original content
    if ctx.file_exists(path):
        old_content = ctx.file_read(path)
    else:
        old_content = ""

    changed = new_content != old_content

    # Backup if requested
    if changed and backup:
        if ctx.file_exists(path):
            backup_content = ctx.file_read(path)
            backup_path = path + "." + str(hash(path)) + ".bak"
            ctx.file_write(backup_path, backup_content)

    # Write to destination
    ctx.file_write(path, new_content, mode="0644")

    # Apply file attributes (mode, owner, group)
    if params.get("mode") != None:
        ctx.run(["chmod", params["mode"], path])
    if params.get("owner") != None:
        ctx.run(["chown", params["owner"], path])
    if params.get("group") != None:
        ctx.run(["chgrp", params["group"], path])

    # Clean up temp file
    if ctx.file_exists(tmpfile):
        ctx.run(["rm", "-f", tmpfile])

    if changed:
        return {"changed": True, "msg": "config updated"}
    else:
        return {"changed": False, "msg": "config already correct"}
