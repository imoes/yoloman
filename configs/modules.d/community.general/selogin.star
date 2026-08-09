def main(ctx, params):
    login = params["login"]
    seuser = params.get("seuser")
    serange = params.get("selevel", "s0")
    state = params.get("state", "present")
    do_reload = params.get("reload", True)
    ignore_selinux_state = params.get("ignore_selinux_state", False)

    # Validate required parameters
    if state == "present" and seuser == None:
        fail("seuser is required when state is present")

    # Check SELinux runtime status
    if not ignore_selinux_state:
        res = ctx.run(["getenforce"])
        if res.rc != 0:
            fail("failed to get SELinux enforcement status: " + res.stderr)
        enforce = res.stdout.strip()
        if enforce != "Enforcing" and enforce != "Permissive":
            fail("SELinux is disabled on this host.")

    # Check if selinux user mapping exists and get current value
    res = ctx.run(["semanage", "login", "-l"], mutates=False)
    if res.rc != 0:
        fail("failed to list SELinux login mappings: " + res.stderr)
    
    # Parse output to find the login mapping
    found = False
    current_seuser = None
    current_serange = None
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            # Format: login | seuser | serange (or similar)
            # Handle different output formats (some have extra fields)
            login_field = parts[0].strip()
            if login_field == login or (login.startswith("%") and login_field.startswith(login)):
                found = True
                current_seuser = parts[1].strip() if len(parts) > 1 else None
                current_serange = parts[2].strip() if len(parts) > 2 else None
                break

    # Determine if change is needed
    if state == "present":
        if found and current_seuser == seuser and current_serange == serange:
            return {"changed": False, "msg": "mapping already exists"}
        # In check mode, return predicted change
        if ctx.check_mode:
            return {"changed": True, "msg": "would add or modify SELinux login mapping"}
        # Perform the modification or addition
        if found:
            # Modify existing mapping
            res = ctx.run([
                "semanage", "login", "-m", "-s", seuser, "-r", serange, login
            ])
        else:
            # Add new mapping
            res = ctx.run([
                "semanage", "login", "-a", "-s", seuser, "-r", serange, login
            ])
        if res.rc != 0:
            fail("failed to " + ("modify" if found else "add") + " SELinux login mapping: " + res.stderr)
        # Reload policy if requested
        if do_reload:
            res = ctx.run(["semodule", "-r", "base"])
            if res.rc != 0:
                fail("failed to reload SELinux policy: " + res.stderr)
        return {"changed": True, "msg": "SELinux login mapping " + ("modified" if found else "added")}
    elif state == "absent":
        if not found:
            return {"changed": False, "msg": "mapping does not exist"}
        # In check mode, return predicted change
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove SELinux login mapping"}
        # Remove the mapping
        res = ctx.run(["semanage", "login", "-d", login])
        if res.rc != 0:
            fail("failed to remove SELinux login mapping: " + res.stderr)
        # Reload policy if requested
        if do_reload:
            res = ctx.run(["semodule", "-r", "base"])
            if res.rc != 0:
                fail("failed to reload SELinux policy: " + res.stderr)
        return {"changed": True, "msg": "SELinux login mapping removed"}
    else:
        fail("invalid state: " + state)
