def main(ctx, params):
    service = params["service"]
    username = params["username"]
    keyring_password = params["keyring_password"]
    user_password = params.get("user_password")
    state = params.get("state", "present")

    if state not in ("present", "absent"):
        fail("unsupported state: " + state)

    # Get current password using keyring get command (shell fallback path)
    # Check for presence by attempting to get the password
    get_cmd = [
        "dbus-run-session",
        "--",
        "/bin/bash",
        "-c",
        'echo "' + keyring_password.replace('"', '\\"') + '" | gnome-keyring-daemon --unlock\nkeyring get ' + service.replace('"', '\\"') + ' ' + username.replace('"', '\\"') + '\n',
    ]
    res_get = ctx.run(get_cmd, mutates=False)

    if res_get.rc != 0:
        fail("failed to check existing password: " + res_get.stderr)

    # Parse output: first line is prompt, second line is password (if exists)
    lines = res_get.stdout.splitlines()
    existing_password = lines[1] if len(lines) > 1 else None

    if state == "absent":
        if existing_password == None:
            return {"changed": False, "msg": "Passphrase already absent for " + username + "@" + service}
        # Delete password
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete passphrase for " + username + "@" + service}
        del_cmd = [
            "dbus-run-session",
            "--",
            "/bin/bash",
            "-c",
            'echo "' + keyring_password.replace('"', '\\"') + '" | gnome-keyring-daemon --unlock\nkeyring del ' + service.replace('"', '\\"') + ' ' + username.replace('"', '\\"') + '\n',
        ]
        res_del = ctx.run(del_cmd, mutates=True)
        if res_del.rc != 0:
            fail("failed to delete passphrase: " + res_del.stderr)
        return {"changed": True, "msg": "Passphrase has been removed for " + username + "@" + service}

    # state == "present"
    if existing_password != None and existing_password == user_password:
        return {"changed": False, "msg": "Passphrase already set for " + username + "@" + service}

    # Set or update password
    if ctx.check_mode:
        return {"changed": True, "msg": "would set password for " + username + "@" + service}

    set_cmd = [
        "dbus-run-session",
        "--",
        "/bin/bash",
        "-c",
        'echo "' + keyring_password.replace('"', '\\"') + '" | gnome-keyring-daemon --unlock\nkeyring set ' + service.replace('"', '\\"') + ' ' + username.replace('"', '\\"') + '\n' + user_password.replace('"', '\\"') + '\n',
    ]
    res_set = ctx.run(set_cmd, mutates=True)
    if res_set.rc != 0:
        fail("failed to set password: " + res_set.stderr)

    return {"changed": True, "msg": "Passphrase has been updated for " + username + "@" + service}
