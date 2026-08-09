def main(ctx, params):
    key = params["key"]
    state = params.get("state", "present")
    value = params.get("value")

    # Validate required params per state
    if state == "present" and value == None:
        ctx.fail("state=present requires value")

    # Normalize value: booleans -> 'true'/'false' strings, others to str
    if value != None:
        if type(value) == bool:
            value = "true" if value else "false"
        else:
            value = str(value)

    # Probes for dconf binary availability
    res = ctx.run(["which", "dconf"])
    if res.rc != 0:
        ctx.fail("dconf binary not found in PATH")

    # Helper to read current value
    def read_value():
        res = ctx.run(["dconf", "read", key])
        if res.rc != 0:
            ctx.fail("dconf failed while reading key " + key + ": " + res.stderr)
        # Empty output means unset (None); strip trailing newline if present
        out = res.stdout
        if out == "":
            return None
        return out.rstrip("\n")

    # Helper to write value via dconf write (requires DBus)
    def write_value():
        # Check if change needed (with fallback string comparison if gi not available)
        current = read_value()
        # Simple string equality fallback (gi.repository not available in Starlark)
        if current == value:
            return False
        if ctx.check_mode:
            return True

        # Write command wrapped in dbus-run-session (required for dconf writes)
        res = ctx.run(["dbus-run-session", "dconf", "write", key, value], mutates=True)
        if res.skipped:
            return True
        if res.rc != 0:
            ctx.fail("dconf failed while writing key " + key + " with value " + value + ": " + res.stderr)
        return True

    # Helper to reset key via dconf reset
    def reset_key():
        current = read_value()
        if current == None:
            return False
        if ctx.check_mode:
            return True

        res = ctx.run(["dbus-run-session", "dconf", "reset", key], mutates=True)
        if res.skipped:
            return True
        if res.rc != 0:
            ctx.fail("dconf failed while resetting key " + key + ": " + res.stderr)
        return True

    # State handling
    if state == "read":
        current = read_value()
        return {"changed": False, "value": current}

    if state == "present":
        changed = write_value()
        return {"changed": changed}

    if state == "absent":
        changed = reset_key()
        return {"changed": changed}

    ctx.fail("unsupported state: " + state)
