def main(ctx, params):
    host = params.get("host")
    login = params.get("login", "Administrator")
    password = params.get("password", "admin")
    media = params.get("media")
    image = params.get("image")
    state = params.get("state", "boot_once")
    force = params.get("force", False)
    ssl_version = params.get("ssl_version", "TLSv1")

    if host == None:
        fail("host is required")
    if state not in ("boot_always", "boot_once", "connect", "disconnect", "no_boot", "poweroff"):
        fail("unsupported state: %s" % state)
    if media != None and media not in ("cdrom", "floppy", "rbsu", "hdd", "network", "normal", "usb"):
        fail("unsupported media: %s" % media)
    if ssl_version not in ("SSLv3", "SSLv23", "TLSv1", "TLSv1_1", "TLSv1_2"):
        fail("unsupported ssl_version: %s" % ssl_version)

    ssl_map = {
        "SSLv3": "SSLv3",
        "SSLv23": "SSLv23",
        "TLSv1": "TLSv1",
        "TLSv1_1": "TLSv1_1",
        "TLSv1_2": "TLSv1_2",
    }
    ssl_ver = ssl_map.get(ssl_version, "TLSv1")

    # Build the command for hpilo_boot
    cmd = [
        "hpilo_boot",
        "--host", host,
        "--login", login,
        "--password", password,
        "--state", state,
        "--ssl-version", ssl_ver
    ]

    if media != None:
        cmd.extend(["--media", media])
    if image != None:
        cmd.extend(["--image", image])
    if force:
        cmd.append("--force")

    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        # check_mode: predict change
        return {"changed": True, "msg": "would execute hpilo_boot"}

    if res.rc != 0:
        fail("hpilo_boot failed: " + res.stderr)

    # Parse output for power status and other details if present
    out = res.stdout.strip()
    power_status = "UNKNOWN"
    status_dict = {}

    # Try to extract power status if present in output
    if "power=" in out:
        parts = out.split()
        for p in parts:
            if p.startswith("power="):
                power_status = p.split("=", 1)[1]
    else:
        # Fallback: assume changed if no error
        pass

    return {"changed": True, "msg": "hpilo_boot completed", "power": power_status, "data": status_dict}
