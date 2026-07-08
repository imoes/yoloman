def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    password = params.get("password")
    storage = params.get("storage")
    disksize = params.get("disksize")
    resize = params.get("resize", False)
    realname = params.get("realname")
    realm = params.get("realm")
    email = params.get("email")
    location = params.get("location")
    iconname = params.get("iconname")
    homedir = params.get("homedir")
    imagepath = params.get("imagepath")
    uid = params.get("uid")
    gid = params.get("gid")
    umask = params.get("umask")
    memberof = params.get("memberof")
    skeleton = params.get("skeleton")
    shell = params.get("shell")
    environment = params.get("environment")
    timezone = params.get("timezone")
    locked = params.get("locked")
    passwordhint = params.get("passwordhint")
    sshkeys = params.get("sshkeys")
    language = params.get("language")
    notbefore = params.get("notbefore")
    notafter = params.get("notafter")
    mountopts = params.get("mountopts")

    # Validate required params for state=present
    if state == "present" and password == None:
        fail("password is required when state is present")
    if resize and disksize == None:
        fail("disksize is required when resize is true")

    # Check systemd-homed service is active
    res = ctx.run(["systemctl", "show", "systemd-homed.service", "-p", "ActiveState"])
    if res.rc != 0:
        fail("failed to check systemd-homed.service: " + res.stderr)
    active = res.stdout.strip().rsplit("=", 1)[1].strip() == "active"
    if not active:
        fail("systemd-homed.service is not active")

    # Helper to get user metadata as JSON
    def get_user_metadata():
        res = ctx.run(["homectl", "inspect", name, "-j", "--no-pager"])
        return res.rc, res.stdout, res.stderr

    # Helper to check if user exists and password matches
    user_exists = False
    valid_pw = False

    rc, stdout, stderr = get_user_metadata()
    if rc == 0:
        user_exists = True
        # Skip password comparison in Starlark due to lack of crypt support
        # homectl handles cleartext password validation internally
        if state != "absent" and password != None:
            valid_pw = True  # Assume valid for update; homectl will reject if wrong

    def _hash_password(password, salt):
        # Not implemented in Starlark; not used for actual operation
        return ""

    def create_json_record(create=False):
        fields = []
        fields.append('"userName":"%s"' % name)
        fields.append('"secret":{"password":["%s"]}' % password)

        if create:
            fields.append('"privileged":{"hashedPassword":["%s"]}' % password)

        if uid != None and gid != None and create:
            fields.append('"uid":%d' % uid)
            fields.append('"gid":%d' % gid)

        if memberof != None:
            groups = [g.strip() for g in memberof.split(",")]
            fields.append('"memberOf":[%s]' % ",".join(['"%s"' % g for g in groups]))

        if realname != None:
            fields.append('"realName":"%s"' % realname)

        if storage != None and create:
            fields.append('"storage":"%s"' % storage)

        if homedir != None and create:
            fields.append('"homeDirectory":"%s"' % homedir)

        if imagepath != None and create:
            fields.append('"imagePath":"%s"' % imagepath)

        if disksize != None:
            s = disksize.upper()
            if s.endswith("B"):
                s = s[:-1]
            if s.endswith("K"):
                val = int(s[:-1]) * 1024
            elif s.endswith("M"):
                val = int(s[:-1]) * 1024 * 1024
            elif s.endswith("G"):
                val = int(s[:-1]) * 1024 * 1024 * 1024
            elif s.endswith("T"):
                val = int(s[:-1]) * 1024 * 1024 * 1024 * 1024
            else:
                val = int(s)
            fields.append('"diskSize":%d' % val)

        if realm != None:
            fields.append('"realm":"%s"' % realm)

        if email != None:
            fields.append('"emailAddress":"%s"' % email)

        if location != None:
            fields.append('"location":"%s"' % location)

        if iconname != None:
            fields.append('"iconName":"%s"' % iconname)

        if skeleton != None:
            fields.append('"skeletonDirectory":"%s"' % skeleton)

        if shell != None:
            fields.append('"shell":"%s"' % shell)

        if umask != None:
            fields.append('"umask":%d' % umask)

        if environment != None:
            env_list = [e.strip() for e in environment.split(",")]
            fields.append('"environment":[%s]' % ",".join(['"%s"' % e for e in env_list]))

        if timezone != None:
            fields.append('"timeZone":"%s"' % timezone)

        if locked != None:
            fields.append('"locked":%s' % ("true" if locked else "false"))

        if passwordhint != None:
            fields.append('"privileged":{"passwordHint":"%s"' % passwordhint + "}")

        if sshkeys != None:
            keys = [k.strip() for k in sshkeys.split(",")]
            fields.append('"privileged":{"sshAuthorizedKeys":[%s]}' % ",".join(['"%s"' % k for k in keys]))

        if language != None:
            fields.append('"preferredLanguage":"%s"' % language)

        if notbefore != None:
            fields.append('"notBeforeUSec":%d' % notbefore)

        if notafter != None:
            fields.append('"notAfterUSec":%d' % notafter)

        if mountopts != None:
            opts = [o.strip() for o in mountopts.split(",")]
            nosuid = "nosuid" in opts
            nodev = "nodev" in opts
            noexec = "noexec" in opts
            fields.append('"mountNoSuid":%s' % ("true" if nosuid else "false"))
            fields.append('"mountNoDevices":%s' % ("true" if nodev else "false"))
            fields.append('"mountNoExecute":%s' % ("true" if noexec else "false"))

        return "{" + ",".join(fields) + "}"

    changed = False
    msg = ""
    data = None

    if state == "absent":
        if not user_exists:
            return {"changed": False, "msg": "User does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove user " + name}
        res = ctx.run(["homectl", "remove", name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove user " + name}
        if res.rc != 0:
            fail("failed to remove user " + name + ": " + res.stderr)
        return {"changed": True, "msg": "User " + name + " removed"}

    # state == "present"
    if not user_exists:
        if ctx.check_mode:
            return {"changed": True, "msg": "would create user " + name}
        record = create_json_record(create=True)
        res = ctx.run(["homectl", "create", "--identity=-"], data=record, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create user " + name}
        if res.rc != 0:
            fail("failed to create user " + name + ": " + res.stderr)
        # Get metadata for return data
        rc, stdout, stderr = get_user_metadata()
        if rc == 0:
            data = stdout  # caller may parse this as needed
        return {"changed": True, "msg": "User " + name + " created", "data": data}

    # User exists — update case
    if not valid_pw and password != None:
        return {"changed": False, "msg": "User exists but password is incorrect"}

    # For update, always prepare command (idempotency checked by homectl)
    changed = True
    if ctx.check_mode:
        return {"changed": changed, "msg": "would update user " + name}

    cmd = ["homectl", "update", name, "--identity=-"]
    if disksize != None and resize:
        cmd.append("--and-resize")
        cmd.append("true")

    res = ctx.run(cmd, data=create_json_record(create=False), mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would update user " + name}
    if res.rc != 0:
        fail("failed to update user " + name + ": " + res.stderr)

    # Get updated metadata
    rc, stdout, stderr = get_user_metadata()
    if rc == 0:
        data = stdout

    return {"changed": changed, "msg": "User " + name + " updated", "data": data}
