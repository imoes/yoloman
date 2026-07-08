def main(ctx, params):
    path = params["path"]
    namespace = params.get("namespace", "user")
    key = params.get("key")
    value = params.get("value")
    state = params.get("state", "read")
    follow = params.get("follow", True)

    # Validate path exists
    if not ctx.file_exists(path):
        fail("path not found or not accessible!")

    # Validate state+key combination
    if key == None and state in ["absent", "present"]:
        fail("%s needs a key parameter" % state)

    # Construct full key with namespace
    full_key = key
    if key != None and namespace != None and len(namespace) > 0:
        if not (namespace == "user" and key.startswith("user.")):
            full_key = namespace + "." + key

    # Normalize value None for state comparison
    value_provided = value != None
    effective_state = "present" if value_provided else state

    changed = False
    msg = ""
    res = {}

    if effective_state == "present":
        # Get current value
        current = _get_xattr(ctx, path, full_key, follow)
        if current == None or full_key not in current or current.get(full_key) != value:
            if not ctx.check_mode:
                _set_xattr(ctx, path, full_key, value, follow)
            changed = True
        res = current if current != None else {}
        msg = "%s set to %s" % (full_key, str(value))
    elif effective_state == "absent":
        current = _get_xattr(ctx, path, full_key, follow)
        if current != None and full_key in current:
            if not ctx.check_mode:
                _rm_xattr(ctx, path, full_key, follow)
            changed = True
        res = current if current != None else {}
        msg = "%s removed" % full_key
    elif effective_state == "keys":
        res = _get_xattr_keys(ctx, path, follow)
        msg = "returning all keys"
    elif effective_state == "all":
        res = _get_xattr(ctx, path, None, follow)
        msg = "dumping all"
    else:  # 'read'
        res = _get_xattr(ctx, path, full_key, follow)
        msg = "returning %s" % full_key

    return {"changed": changed, "msg": msg, "xattr": res}


def _get_xattr_keys(ctx, path, follow):
    cmd = ["getfattr", "--absolute-names"]
    if not follow:
        cmd.append("-h")
    cmd.append(path)
    res = ctx.run(cmd, mutates=False)
    return _parse_xattr_output(res.stdout)


def _get_xattr(ctx, path, key, follow):
    cmd = ["getfattr", "--absolute-names"]
    if not follow:
        cmd.append("-h")
    if key == None:
        cmd.append("-d")
    else:
        cmd.extend(["-n", key])
    cmd.append(path)
    res = ctx.run(cmd, mutates=False)
    return _parse_xattr_output(res.stdout)


def _set_xattr(ctx, path, key, value, follow):
    cmd = ["setfattr"]
    if not follow:
        cmd.append("-h")
    cmd.extend(["-n", key, "-v", value, path])
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("failed to set xattr: " + res.stderr)


def _rm_xattr(ctx, path, key, follow):
    cmd = ["setfattr"]
    if not follow:
        cmd.append("-h")
    cmd.extend(["-x", key, path])
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("failed to remove xattr: " + res.stderr)


def _parse_xattr_output(output):
    result = {}
    if output == None:
        return None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or stripped == "":
            continue
        eq_idx = stripped.find("=")
        if eq_idx >= 0:
            k = stripped[:eq_idx]
            v = stripped[eq_idx+1:].strip('"')
            result[k] = v
        else:
            result[stripped] = ""
    return result
