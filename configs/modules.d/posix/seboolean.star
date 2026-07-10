def main(ctx, params):
    name = params["name"]
    persistent = params.get("persistent", False)
    state = params["state"]
    ignore_selinux_state = params.get("ignore_selinux_state", False)

    # Check SELinux is enabled (unless ignored)
    if not ignore_selinux_state:
        res = ctx.run(["getenforce"], mutates=False)
        if res.rc != 0 or res.stdout.strip() != "Enforcing":
            # Also check permissive
            res2 = ctx.run(["getenforce"], mutates=False)
            if res2.rc == 0 and res2.stdout.strip() == "Permissive":
                pass  # Allow permissive mode as SELinux is still active
            elif res.rc != 0 or "Disabled" in res.stdout:
                fail("SELinux is disabled on this host.")

    # Check if boolean exists (via getsebool)
    res = ctx.run(["getsebool", name], mutates=False)
    if res.rc != 0 or "unknown boolean" in res.stdout.lower():
        fail("SELinux boolean " + name + " does not exist.")

    # Get current runtime value
    # getsebool outputs: boolean_name --- value
    lines = res.stdout.strip().splitlines()
    current = None
    for line in lines:
        if line.startswith(name):
            parts = line.split()
            if len(parts) >= 3 and parts[2] in ("on", "off"):
                current = (parts[2] == "on")
                break
    if current == None:
        fail("Failed to determine current value for boolean " + name)

    # Determine desired state
    desired = bool(state)

    if persistent:
        # For persistent changes, we need semanage
        # Check semanage availability by trying to run semanage --version
        res = ctx.run(["semanage", "--version"], mutates=False)
        if res.rc != 0:
            fail("semanage command not available; cannot set persistent booleans")

        # Get persistent value using semanage boolean -l
        res = ctx.run(["semanage", "boolean", "-l"], mutates=False)
        if res.rc != 0:
            fail("Failed to query persistent boolean state with semanage")
        persistent_val = None
        for line in res.stdout.splitlines():
            if name in line:
                if "on" in line:
                    persistent_val = True
                elif "off" in line:
                    persistent_val = False
                break
        if persistent_val == None:
            fail("Failed to determine persistent value for boolean " + name)

        if persistent_val != desired:
            # Change persistent value
            if ctx.check_mode:
                return {"changed": True, "msg": "would set persistent boolean " + name + " to " + ("on" if desired else "off")}
            # Use semanage boolean -m to modify
            res = ctx.run(["semanage", "boolean", "-m", "-1" if desired else "0", "--", name], mutates=True)
            if res.rc != 0:
                fail("Failed to set persistent boolean " + name + ": " + res.stderr)
            # Commit changes
            res = ctx.run(["semanage", "commit"], mutates=True)
            if res.rc != 0:
                fail("Failed to commit semanage changes: " + res.stderr)
            # Set runtime value as well
            res = ctx.run(["setsebool", "-p", name, "1" if desired else "0"], mutates=True)
            if res.rc != 0:
                fail("Failed to set runtime value for boolean " + name + ": " + res.stderr)
            return {"changed": True, "msg": "set persistent boolean " + name + " to " + ("on" if desired else "off")}
        else:
            # Already matches persistent value, but runtime may differ
            if current != desired:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would set runtime boolean " + name + " to " + ("on" if desired else "off")}
                res = ctx.run(["setsebool", name, "1" if desired else "0"], mutates=True)
                if res.rc != 0:
                    fail("Failed to set runtime value for boolean " + name + ": " + res.stderr)
                return {"changed": True, "msg": "set runtime boolean " + name + " to " + ("on" if desired else "off")}
            return {"changed": False, "msg": "boolean " + name + " already set as desired"}
    else:
        # Non-persistent: only change runtime
        if current == desired:
            return {"changed": False, "msg": "boolean " + name + " already set to " + ("on" if desired else "off")}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would set boolean " + name + " to " + ("on" if desired else "off")}
            res = ctx.run(["setsebool", name, "1" if desired else "0"], mutates=True)
            if res.rc != 0:
                fail("Failed to set boolean " + name + ": " + res.stderr)
            # Ensure the change is effective (setsebool commits immediately)
            return {"changed": True, "msg": "set boolean " + name + " to " + ("on" if desired else "off")}
