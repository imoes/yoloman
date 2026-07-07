def main(ctx, params):
    path = params["path"]
    state = params.get("state", "present")
    force = params.get("force", False)
    format_ = params.get("format", "PEM")
    privatekey_path = params.get("privatekey_path")
    privatekey_content = params.get("privatekey_content")
    privatekey_passphrase = params.get("privatekey_passphrase")
    backup = params.get("backup", False)
    return_content = params.get("return_content", False)

    # Validate privatekey inputs
    if state == "present":
        if privatekey_path == None and privatekey_content == None:
            fail("one of privatekey_path or privatekey_content is required for state=present")
        if privatekey_path != None and privatekey_content != None:
            fail("only one of privatekey_path or privatekey_content must be specified")

    # Check for backend override (unsupported)
    if params.get("select_crypto_backend") != None and params.get("select_crypto_backend") != "auto":
        fail("only backend 'auto' is supported")

    # Verify directory exists (for present state)
    if state == "present":
        dir_path = path.rsplit("/", 1)[0] if "/" in path else "."
        if not ctx.file_exists(dir_path):
            fail("The directory '%s' does not exist or the file is not a directory" % dir_path)

    # Check mode
    if ctx.check_mode:
        if state == "absent":
            changed = ctx.file_exists(path)
            return {
                "changed": changed,
                "msg": "would remove %s" % path if changed else "%s does not exist" % path,
            }
        else:
            if ctx.file_exists(path) and not force:
                return {
                    "changed": False,
                    "msg": "public key already exists",
                }
            else:
                return {
                    "changed": True,
                    "msg": "would generate public key",
                }

    # Handle absent state
    if state == "absent":
        if ctx.file_exists(path):
            backup_file = None
            if backup:
                # Generate timestamp without time module
                res = ctx.run(["date", "+%Y-%m-%d@%H:%M:%S"])
                if res.rc == 0:
                    timestamp = res.stdout.strip()
                    backup_path = "%s.%s" % (path, timestamp)
                    ctx.file_write(backup_path, ctx.file_read(path))
                    backup_file = backup_path
                else:
                    fail("failed to get timestamp for backup: " + res.stderr)
            ctx.run(["rm", "-f", path], mutates=True)
            result = {
                "changed": True,
                "msg": "removed %s" % path,
                "filename": path,
                "privatekey": privatekey_path,
                "format": format_,
            }
            if backup_file != None:
                result["backup_file"] = backup_file
            if return_content and ctx.file_exists(path):
                result["publickey"] = ctx.file_read(path)
            return result
        else:
            return {
                "changed": False,
                "msg": "%s does not exist" % path,
            }

    # Present state: cannot implement without external crypto
    fail("this module requires external cryptographic capabilities and cannot be implemented in pure Starlark")
