def main(ctx, params):
    path = params["path"]
    username = params["name"]
    password = params.get("password")
    hash_scheme = params.get("hash_scheme", "apr_md5_crypt")
    state = params.get("state", "present")
    create = params.get("create", True)

    # Validate required options
    if state == "present" and password == None:
        fail("password is required when state is present")

    # Read current file content if exists
    current_content = ""
    if ctx.file_exists(path):
        current_content = ctx.file_read(path)

    # Handle blank lines in existing file (to avoid parsing errors)
    lines = []
    if current_content != "":
        lines = current_content.split("\n")
    has_blank = False
    for i in range(len(lines)):
        if lines[i].strip() == "":
            has_blank = True
            break

    if has_blank and not ctx.check_mode:
        new_lines = []
        for i in range(len(lines)):
            if lines[i].strip() != "":
                new_lines.append(lines[i])
        current_content = "\n".join(new_lines)

    # Determine if user exists
    user_found = False
    if current_content != "":
        lines = current_content.split("\n")
        for i in range(len(lines)):
            line = lines[i]
            if line.strip() == "":
                continue
            colon_pos = line.find(":")
            if colon_pos > 0:
                name = line[:colon_pos]
                if name == username:
                    user_found = True
                    break

    # For absent state
    if state == "absent":
        if not user_found:
            return {"changed": False, "msg": username + " not present"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove " + username}
        # We must remove the user line
        new_lines = []
        if current_content != "":
            for i in range(len(lines)):
                line = lines[i]
                if line.strip() == "":
                    continue
                colon_pos = line.find(":")
                name = line[:colon_pos] if colon_pos > 0 else ""
                if name != username:
                    new_lines.append(line)
        new_content = "\n".join(new_lines)
        if new_content == current_content:
            return {"changed": False, "msg": username + " not present"}
        changed = ctx.file_write(path, new_content)
        return {"changed": changed, "msg": "removed " + username}

    # For present state
    if user_found:
        return {"changed": False, "msg": username + " already present"}

    # Create or update
    if not ctx.file_exists(path):
        if not create:
            fail("destination %s does not exist and create is false" % path)
        if ctx.check_mode:
            return {"changed": True, "msg": "would create %s and add %s" % (path, username)}
        # Create missing directories
        parent = ""
        last_slash = path.rfind("/")
        if last_slash > 0:
            parent = path[:last_slash]
        if parent != "" and not ctx.file_exists(parent):
            ctx.run(["mkdir", "-p", parent])
        # Plaintext only
        if hash_scheme != "plaintext":
            fail("password hashing not supported in Starlark; use hash_scheme=plaintext for testing")
        new_content = username + ":" + password
        changed = ctx.file_write(path, new_content)
        return {"changed": changed, "msg": "created %s and added %s" % (path, username)}

    # Update existing user
    if ctx.check_mode:
        return {"changed": True, "msg": "would update " + username}

    # Reconstruct file without old entry, then add new one
    new_lines = []
    if current_content != "":
        lines = current_content.split("\n")
        for i in range(len(lines)):
            line = lines[i]
            if line.strip() == "":
                continue
            colon_pos = line.find(":")
            name = line[:colon_pos] if colon_pos > 0 else ""
            if name != username:
                new_lines.append(line)
    if hash_scheme != "plaintext":
        fail("password hashing not supported in Starlark; use hash_scheme=plaintext for testing")
    new_lines.append(username + ":" + password)
    new_content = "\n".join(new_lines)
    if new_content == current_content:
        return {"changed": False, "msg": username + " already present"}
    changed = ctx.file_write(path, new_content)

    return {"changed": changed, "msg": "added/updated " + username}
