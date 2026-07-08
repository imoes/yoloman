def main(ctx, params):
    service = params["service"]
    username = params["username"]
    keyring_password = params["keyring_password"]

    # Check for Python keyring library availability by attempting to import it
    # via a shell one-liner (since Starlark has no import mechanism)
    import_check = ctx.run([
        "python3", "-c", "import keyring; print('OK')"
    ], mutates=False)
    
    if import_check.rc != 0:
        fail("Failed to import keyring module. Please install keyring Python library and ensure gnome-keyring is available.")

    # Try primary method: direct Python keyring call
    primary_attempt = ctx.run([
        "python3", "-c",
        "import keyring; print(keyring.get_password(%s, %s) or '')" % (
            repr(service), repr(username)
        )
    ], mutates=False)
    
    passphrase = primary_attempt.stdout.strip()
    if passphrase != "":
        return {
            "changed": False,
            "msg": "Successfully retrieved password for " + username + "@" + service,
            "data": {"passphrase": passphrase}
        }

    # If primary failed, try alternate method using gnome-keyring-daemon
    unlock_cmd = 'echo "%s" | gnome-keyring-daemon --unlock' % keyring_password.replace('"', '\\"')
    get_cmd = 'keyring get %s %s' % (service.replace('"', '\\"'), username.replace('"', '\\"'))
    full_script = unlock_cmd + "\n" + get_cmd
    
    alternate = ctx.run([
        "dbus-run-session", "--", "/bin/bash", "-c", full_script
    ], mutates=False)
    
    lines = alternate.stdout.splitlines()
    passphrase = lines[1] if len(lines) > 1 else None
    
    if passphrase != None and passphrase.strip() != "":
        return {
            "changed": False,
            "msg": "Successfully retrieved password for " + username + "@" + service + " (via alternate method)",
            "data": {"passphrase": passphrase.strip()}
        }

    # Final fallback: password not found
    return {
        "changed": False,
        "msg": "Password for " + username + "@" + service + " does not exist."
    }
