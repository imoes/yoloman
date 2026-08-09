def main(ctx, params):
    username = params["username"]
    host = params["host"]
    password = params.get("password")
    state = params.get("state", "present")
    logging_flag = params.get("logging", False)

    # Logging support is not implemented since Starlark has no syslog access.
    # Fail if logging is requested.
    if logging_flag:
        fail("logging option is not supported in Starlark runtime")

    # Validate state is present or absent
    if state not in ("present", "absent"):
        fail("unsupported state: " + state)

    # Required password for present state
    if state == "present" and password == None:
        fail("password is required when state=present")

    # Check if user exists: use ejabberdctl check_account
    res_check = ctx.run(["ejabberdctl", "check_account", username, host], mutates=False)
    user_exists = (res_check.rc == 0)

    # Determine desired state
    if state == "absent":
        if not user_exists:
            return {"changed": False, "msg": "user already absent"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove user"}
        res_del = ctx.run(["ejabberdctl", "unregister", username, host], mutates=True)
        if res_del.skipped:
            return {"changed": True, "msg": "would remove user"}
        if res_del.rc != 0:
            fail("failed to remove user: " + res_del.stderr)
        return {"changed": True, "msg": "user removed"}

    # state == "present"
    if not user_exists:
        # Create user: ejabberdctl register username host password
        if ctx.check_mode:
            return {"changed": True, "msg": "would create user"}
        res_create = ctx.run(["ejabberdctl", "register", username, host, password], mutates=True)
        if res_create.skipped:
            return {"changed": True, "msg": "would create user"}
        if res_create.rc != 0:
            fail("failed to create user: " + res_create.stderr)
        return {"changed": True, "msg": "user created"}

    # User exists; check if password needs update
    res_check_pwd = ctx.run(["ejabberdctl", "check_password", username, host, password], mutates=False)
    pwd_ok = (res_check_pwd.rc == 0)

    if pwd_ok:
        return {"changed": False, "msg": "user already exists with correct password"}

    # Update password: ejabberdctl change_password username host password
    if ctx.check_mode:
        return {"changed": True, "msg": "would update user password"}
    res_update = ctx.run(["ejabberdctl", "change_password", username, host, password], mutates=True)
    if res_update.skipped:
        return {"changed": True, "msg": "would update user password"}
    if res_update.rc != 0:
        fail("failed to update password: " + res_update.stderr)
    return {"changed": True, "msg": "user password updated"}
