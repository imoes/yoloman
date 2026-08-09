def main(ctx, params):
    name = params["name"]
    description = params.get("description")
    position = params.get("position", "")
    ou = params.get("ou", "")
    subpath = params.get("subpath", "cn=groups")
    state = params.get("state", "present")

    # Build container DN
    if position != "":
        container = position
    else:
        ou_part = "ou=%s," % ou if ou != "" else ""
        subpath_part = "%s," % subpath if subpath != "" else ""
        # ctx.facts() should include 'hostname' and domain info is not available via ctx
        # As the original relies on base_dn(), which is UCS-specific and not accessible via ctx,
        # we must fail if position not provided and no way to determine base_dn.
        fail("position orou + base_dn() required; base_dn() not available via Starlark ctx")

    group_dn = "cn=%s,%s" % (name, container)

    # Search for existing group — use simple LDAP filter via run command
    # This assumes univention-ldapsearch is available (UCS-specific)
    res = ctx.run([
        "univention-ldapsearch",
        "-x",
        "-b", container,
        "(&(objectClass=posixGroup)(cn=%s))" % name,
        "dn"
    ])
    groups = []
    for line in res.stdout.split("\n"):
        stripped = line.strip()
        if stripped.startswith("dn: ") and stripped != "dn: ":
            groups.append(stripped[4:])

    exists = len(groups) > 0

    if state == "absent":
        if not exists:
            return {"changed": False, "msg": "group %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove group %s" % name}
        res = ctx.run([
            "univention-service",
            "udm", "groups/group", "remove", group_dn
        ])
        if res.rc != 0:
            fail("failed to remove group %s: %s" % (name, res.stderr))
        return {"changed": True, "msg": "removed group %s" % name}

    if state != "present":
        fail("unsupported state: %s" % state)

    # state == "present"
    if exists:
        # Check if update needed
        res = ctx.run([
            "univention-service",
            "udm", "groups/group", "search", group_dn
        ])
        if res.rc != 0:
            fail("failed to query group %s: %s" % (name, res.stderr))
        # Parse output to extract existing description
        current_desc = None
        for line in res.stdout.split("\n"):
            if line.strip().startswith("description: "):
                current_desc = line.strip()[13:]
                break
        if current_desc == description:
            return {"changed": False, "msg": "group %s already exists with correct description" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would update group %s description" % name}
        # Perform modify
        cmd = ["univention-service", "udm", "groups/group", "modify", "--dn", group_dn]
        if description != None:
            cmd.extend(["--set", "description=%s" % description])
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to modify group %s: %s" % (name, res.stderr))
        return {"changed": True, "msg": "updated group %s" % name}

    # Create new group
    if ctx.check_mode:
        return {"changed": True, "msg": "would create group %s in %s" % (name, container)}

    cmd = [
        "univention-service",
        "udm", "groups/group", "create",
        "--set", "name=%s" % name,
        "--position", container
    ]
    if description != None:
        cmd.extend(["--set", "description=%s" % description])
    res = ctx.run(cmd)
    if res.rc != 0:
        fail("failed to create group %s: %s" % (name, res.stderr))
    return {"changed": True, "msg": "created group %s" % name}
