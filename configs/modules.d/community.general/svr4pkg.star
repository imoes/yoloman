def main(ctx, params):
    name = params["name"]
    state = params["state"]
    src = params.get("src")
    proxy = params.get("proxy")
    response_file = params.get("response_file")
    zone = params.get("zone", "all")
    category = params.get("category", False)

    if state == "present" and src == None:
        fail("src is required when state=present")

    # Probe: check if package is installed
    cmd = ["pkginfo", "-q"]
    if category:
        cmd.append("-c")
    cmd.append(name)
    res = ctx.run(cmd, mutates=False)
    installed = res.rc == 0

    if state == "present":
        if installed:
            return {"changed": False, "msg": name + " already installed"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would install " + name}

        # Create admin file
        adminfile = "/tmp/ansible_svr4pkg_" + name
        admin_content = "mail=\ninstance=unique\npartial=nocheck\nrunlevel=quit\nidepend=nocheck\nrdepend=nocheck\nspace=quit\nsetuid=nocheck\nconflict=nocheck\naction=nocheck\nnetworktimeout=60\nnetworkretries=3\nauthentication=quit\nkeystore=/var/sadm/security\nproxy=\nbasedir=default\n"
        ctx.file_write(adminfile, admin_content, mode="0600")

        # Build pkgadd command
        cmd = ["pkgadd", "-n"]
        if zone == "current":
            cmd.append("-G")
        cmd += ["-a", adminfile, "-d", src]
        if proxy != None:
            cmd += ["-x", proxy]
        if response_file != None:
            cmd += ["-r", response_file]
        if category:
            cmd += ["-Y"]
        cmd.append(name)

        res = ctx.run(cmd, mutates=True)
        # Clean up admin file
        ctx.run(["rm", "-f", adminfile], mutates=True)

        if res.rc in (0, 2, 10, 20):
            return {"changed": True, "msg": "installed " + name}
        if res.rc == 99:
            fail("pkgadd: ERROR: could not process datastream from " + src)
        fail("pkgadd failed with rc=" + str(res.rc) + ": " + res.stderr)

    elif state == "absent":
        if not installed:
            return {"changed": False, "msg": name + " not installed"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove " + name}

        # Create admin file
        adminfile = "/tmp/ansible_svr4pkg_" + name
        admin_content = "mail=\ninstance=unique\npartial=nocheck\nrunlevel=quit\nidepend=nocheck\nrdepend=nocheck\nspace=quit\nsetuid=nocheck\nconflict=nocheck\naction=nocheck\nnetworktimeout=60\nnetworkretries=3\nauthentication=quit\nkeystore=/var/sadm/security\nproxy=\nbasedir=default\n"
        ctx.file_write(adminfile, admin_content, mode="0600")

        # Build pkgrm command
        cmd = ["pkgrm", "-na", adminfile]
        if category:
            cmd += ["-Y"]
        cmd.append(name)

        res = ctx.run(cmd, mutates=True)
        # Clean up admin file
        ctx.run(["rm", "-f", adminfile], mutates=True)

        if res.rc == 0:
            return {"changed": True, "msg": "removed " + name}
        fail("pkgrm failed with rc=" + str(res.rc) + ": " + res.stderr)

    fail("unsupported state: " + state)
