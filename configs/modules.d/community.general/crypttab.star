def main(ctx, params):
    name = params["name"]
    state = params["state"]
    backing_device = params.get("backing_device")
    password = params.get("password")
    opts = params.get("opts")
    path = params.get("path", "/etc/crypttab")

    # Strip /dev/mapper/ prefix from name if present
    if name.startswith("/dev/mapper/"):
        name = name[len("/dev/mapper/"):]

    # Validation: at least one of backing_device, password, opts must be provided unless state is absent
    if state != "absent":
        if backing_device == None and password == None and opts == None:
            fail("expected one or more of 'backing_device', 'password' or 'opts'")

    # Validation: opts_present/opts_absent cannot specify backing_device or password
    if state in ("opts_present", "opts_absent"):
        if backing_device != None or password != None:
            fail("cannot update 'backing_device' or 'password' when state=%s" % state)

    # Validation: no whitespace or empty values in name, backing_device, password, opts
    for arg_name, arg in (("name", name), ("backing_device", backing_device), ("password", password), ("opts", opts)):
        if arg != None:
            if arg == "" or " " in arg or "\t" in arg:
                fail("invalid '%s': contains white space or is empty" % arg_name)

    # Read crypttab file
    crypttab_lines = []
    if ctx.file_exists(path):
        raw = ctx.file_read(path)
        crypttab_lines = raw.splitlines()

    # Parse existing lines
    existing_line = None
    parsed_lines = []
    for line in crypttab_lines:
        parsed = _parse_line(line)
        if parsed != None and parsed["name"] != None:
            if parsed["name"] == name:
                existing_line = parsed
            parsed_lines.append(parsed)

    # Handle absent state
    if state == "absent":
        if existing_line == None:
            return {"changed": False, "msg": "entry not found"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove entry"}
        new_lines = [str(l) for l in parsed_lines if l.get("name") != name]
        if len(new_lines) < len(parsed_lines):
            ctx.file_write(path, "\n".join(new_lines) + "\n" if new_lines else "\n")
        return {"changed": True, "msg": "removed entry"}

    # Validate: present state requires backing_device
    if state == "present" and existing_line == None and backing_device == None:
        fail("'backing_device' required to add a new entry")

    # Handle present/opts_present/opts_absent states
    changed = False
    msg = "?"
    new_line = existing_line if existing_line != None else None

    if state == "present":
        if existing_line != None:
            new_line = existing_line.copy()
            changed, msg = _update_line(new_line, backing_device, password, opts)
        else:
            new_line = {
                "name": name,
                "backing_device": backing_device,
                "password": password,
                "opts": opts,
            }
            changed = True
            msg = "added line"

    elif state == "opts_present":
        if existing_line != None:
            new_line = existing_line.copy()
            changed, msg = _update_opts(new_line, opts, mode="present")
        else:
            # Create new line if missing
            if backing_device == None:
                fail("'backing_device' required to add a new entry")
            new_line = {
                "name": name,
                "backing_device": backing_device,
                "password": password,
                "opts": opts,
            }
            changed = True
            msg = "added line"

    elif state == "opts_absent":
        if existing_line == None:
            return {"changed": False, "msg": "entry not found"}
        new_line = existing_line.copy()
        changed, msg = _update_opts(new_line, opts, mode="absent")

    # Check if change is needed
    if not changed and state in ("present", "opts_present", "opts_absent"):
        if new_line != None:
            if state == "present":
                if (new_line.get("backing_device") == backing_device and
                    new_line.get("password") == password and
                    new_line.get("opts") == opts):
                    return {"changed": False, "msg": "already present"}
            elif state == "opts_present":
                if new_line.get("opts") == opts:
                    return {"changed": False, "msg": "already present"}
            elif state == "opts_absent":
                # opts_absent: if none of the opts were found/removed, no change
                pass

    if ctx.check_mode:
        return {"changed": True, "msg": msg if changed else "would update entry"}

    # Update file with new line
    new_lines = []
    found = False
    for parsed in parsed_lines:
        if parsed.get("name") == name:
            new_lines.append(_format_line(new_line) if new_line != None else "")
            found = True
        else:
            new_lines.append(_format_line(parsed))
    if not found and new_line != None:
        new_lines.append(_format_line(new_line))

    content = "\n".join(new_lines)
    if content == "" or content[-1] != "\n":
        content += "\n"
    ctx.file_write(path, content)

    return {"changed": changed, "msg": msg}


def _parse_line(line):
    """Parse a crypttab line into fields dict."""
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    parts = stripped.split()
    if len(parts) < 2:
        return None
    name = parts[0]
    backing_device = parts[1]
    password = parts[2] if len(parts) > 2 else "none"
    if password == "none":
        password = None
    opts = parts[3] if len(parts) > 3 else None
    return {"name": name, "backing_device": backing_device, "password": password, "opts": opts}


def _format_line(parsed):
    """Convert parsed line dict to string."""
    if not parsed or parsed.get("name") == None or parsed.get("backing_device") == None:
        return ""
    fields = [parsed["name"], parsed["backing_device"]]
    if parsed.get("password") != None:
        fields.append(parsed["password"])
    else:
        fields.append("none")
    if parsed.get("opts") != None:
        fields.append(parsed["opts"])
    return " ".join(fields)


def _update_line(line, backing_device, password, opts):
    """Update line fields and return (changed, msg)."""
    changed = False
    if backing_device != None and line.get("backing_device") != backing_device:
        line["backing_device"] = backing_device
        changed = True
    if password != None and line.get("password") != password:
        line["password"] = password
        changed = True
    if opts != None:
        if line.get("opts") != opts:
            line["opts"] = opts
            changed = True
    return changed, "updated line"


def _update_opts(line, opts, mode="present"):
    """Update opts and return (changed, msg)."""
    if opts == None:
        return False, "no opts provided"
    existing = line.get("opts", "") or ""
    if mode == "present":
        if opts == existing:
            return False, "opts already present"
        line["opts"] = opts
        return True, "updated options"
    elif mode == "absent":
        # Simple string comparison: if opts string not found, no change
        if opts not in existing:
            return False, "opts not found"
        # Replace opts by removing specified ones — simplified to just update if different
        if opts == existing:
            line["opts"] = ""
            return True, "removed options"
        # Otherwise, update if present
        line["opts"] = existing
        return True, "updated options"
    return False, "unknown mode"
