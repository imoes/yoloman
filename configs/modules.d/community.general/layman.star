def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    list_url = params.get("list_url")
    validate_certs = params.get("validate_certs", True)

    # Check layman availability
    res = ctx.run(["which", "layman"])
    if res.rc != 0:
        fail("layman is not installed")

    # Get overlay_defs path from layman config
    res = ctx.run(["layman", "-c"])
    if res.rc != 0:
        fail("failed to get layman configuration: " + res.stderr)
    
    overlay_defs = None
    for line in res.stdout.split("\n"):
        if line.startswith("overlay_defs"):
            parts = line.split("=", 1)
            if len(parts) == 2:
                overlay_defs = parts[1].strip()
                break
    
    if overlay_defs == None:
        fail("overlay_defs not found in layman configuration")

    # Check if overlay is installed
    res = ctx.run(["layman", "-l"])
    if res.rc != 0:
        fail("failed to list overlays: " + res.stderr)
    
    installed = []
    for line in res.stdout.split("\n"):
        stripped = line.strip()
        if stripped and not stripped.startswith("* "):
            continue
        if stripped.startswith("* "):
            stripped = stripped[2:]
        installed.append(stripped)
    
    is_installed = name in installed

    if state == "present":
        if is_installed:
            return {"changed": False, "msg": name + " overlay is already installed"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would add layman repo '" + name + "'"}
        # If not on central list and no list_url provided
        if not layman_has_repo(ctx, name) and list_url == None:
            fail("overlay '" + name + "' is not on the list of known overlays and URL of the remote list was not provided.")
        # Handle alternative list URL
        if not layman_has_repo(ctx, name) and list_url != None:
            dest = overlay_defs + "/" + name + ".xml"
            download_url(ctx, list_url, dest, validate_certs)
        # Add the overlay
        res = ctx.run(["layman", "-a", name])
        if res.rc != 0:
            fail("failed to install overlay " + name + ": " + res.stderr)
        return {"changed": True, "msg": "installed " + name + " overlay"}

    elif state == "updated":
        if name == "ALL":
            if ctx.check_mode:
                return {"changed": True, "msg": "would sync all overlays"}
            res = ctx.run(["layman", "-S"])
            if res.rc != 0:
                fail("failed to sync all overlays: " + res.stderr)
            return {"changed": True, "msg": "synced all overlays"}
        if is_installed:
            if ctx.check_mode:
                return {"changed": True, "msg": "would sync " + name + " overlay"}
            res = ctx.run(["layman", "-s", name])
            if res.rc != 0:
                fail("failed to sync overlay " + name + ": " + res.stderr)
            return {"changed": True, "msg": "synced " + name + " overlay"}
        # Not installed yet, install it
        if ctx.check_mode:
            return {"changed": True, "msg": "would add layman repo '" + name + "'"}
        if not layman_has_repo(ctx, name) and list_url == None:
            fail("overlay '" + name + "' is not on the list of known overlays and URL of the remote list was not provided.")
        if not layman_has_repo(ctx, name) and list_url != None:
            dest = overlay_defs + "/" + name + ".xml"
            download_url(ctx, list_url, dest, validate_certs)
        res = ctx.run(["layman", "-a", name])
        if res.rc != 0:
            fail("failed to install overlay " + name + ": " + res.stderr)
        # Then sync it
        res = ctx.run(["layman", "-s", name])
        if res.rc != 0:
            fail("failed to sync overlay " + name + ": " + res.stderr)
        return {"changed": True, "msg": "installed and synced " + name + " overlay"}

    elif state == "absent":
        if not is_installed:
            return {"changed": False, "msg": name + " overlay is not installed"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove layman repo '" + name + "'"}
        res = ctx.run(["layman", "-d", name])
        if res.rc != 0:
            fail("failed to remove overlay " + name + ": " + res.stderr)
        return {"changed": True, "msg": "removed " + name + " overlay"}

    fail("unsupported state: " + state)


def layman_has_repo(ctx, name):
    res = ctx.run(["layman", "-l"])
    if res.rc != 0:
        return False
    installed = []
    for line in res.stdout.split("\n"):
        stripped = line.strip()
        if stripped.startswith("* "):
            stripped = stripped[2:]
        if stripped:
            installed.append(stripped)
    return name in installed


def download_url(ctx, url, dest, validate_certs):
    # Use wget with --no-check-certificate if validate_certs is false
    args = ["wget", "-O", dest, url]
    if not validate_certs:
        args.insert(1, "--no-check-certificate")
    res = ctx.run(args)
    if res.rc != 0:
        fail("failed to download " + url + ": " + res.stderr)
