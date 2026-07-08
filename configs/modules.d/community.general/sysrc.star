def main(ctx, params):
    name = params["name"]
    value = params.get("value")
    state = params.get("state", "present")
    path = params.get("path", "/etc/rc.conf")
    delim = params.get("delim", " ")
    jail = params.get("jail")

    # OID style names are not supported
    for c in name:
        if not (c.isalnum() or c == "_"):
            fail("Name may only contain alphanumeric and underscore characters")

    # Build sysrc command base
    cmd = ["sysrc", "-f", path]
    if jail != None:
        cmd += ["-j", jail]

    # Helper: run sysrc
    def run_sysrc(*args):
        full_cmd = cmd + list(args)
        res = ctx.run(full_cmd)
        return (res.rc, res.stdout, res.stderr)

    # Check for unknown variable in output
    def has_unknown_variable(out, err):
        return "unknown variable" in out or "unknown variable" in err

    # Check if variable exists with exact value (if value is provided)
    def exists():
        if value == None:
            pattern = name + ": "
        else:
            pattern = name + ": " + value
        rc, out, err = run_sysrc(name)
        if has_unknown_variable(out, err):
            return False
        return out.startswith(pattern)

    # Check if current variable contains the value (for value_present/absent)
    def contains():
        rc, out, err = run_sysrc("-n", name)
        if has_unknown_variable(out, err):
            return False
        current_values = out.strip().split(delim)
        return value in current_values

    # State handlers
    if state == "present":
        if exists():
            return {"changed": False, "msg": name + " already present with correct value"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would set " + name + " to " + value}
        rc, out, err = run_sysrc(name + "=" + value)
        if rc != 0 or not out.startswith(name + ":") or " -> " + value not in out:
            fail("failed to set " + name + ": " + err)
        return {"changed": True, "msg": "set " + name + " to " + value}

    elif state == "absent":
        if not exists():
            return {"changed": False, "msg": name + " already absent"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove " + name}
        rc, out, err = run_sysrc("-x", name)
        if has_unknown_variable(out, err):
            return {"changed": False, "msg": name + " not found to remove"}
        return {"changed": True, "msg": "removed " + name}

    elif state == "value_present":
        if contains():
            return {"changed": False, "msg": name + " already contains value"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would add value to " + name}
        setstring = name + "+=" + delim + value
        rc, out, err = run_sysrc(setstring)
        if rc != 0 or not out.startswith(name + ":"):
            fail("failed to add value to " + name + ": " + err)
        # Verify value was added
        _, new_out, _ = run_sysrc("-n", name)
        if value not in new_out.strip().split(delim):
            fail("value was not added to " + name)
        return {"changed": True, "msg": "added value to " + name}

    elif state == "value_absent":
        if not contains():
            return {"changed": False, "msg": name + " does not contain value"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove value from " + name}
        setstring = name + "-=" + delim + value
        rc, out, err = run_sysrc(setstring)
        if rc != 0 or not out.startswith(name + ":"):
            fail("failed to remove value from " + name + ": " + err)
        # Verify value was removed
        _, new_out, _ = run_sysrc("-n", name)
        if value in new_out.strip().split(delim):
            fail("value was not removed from " + name)
        return {"changed": True, "msg": "removed value from " + name}

    else:
        fail("unsupported state: " + state)
