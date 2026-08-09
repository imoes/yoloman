def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    origin = params.get("origin")
    mirror = params.get("mirror")
    sticky = params.get("sticky")
    enabled = params.get("enabled")

    # Normalize empty list strings to empty list
    if origin != None and len(origin) == 1 and origin[0] == "":
        origin = []
    if mirror != None and len(mirror) == 1 and mirror[0] == "":
        mirror = []

    # Get current publishers
    res = ctx.run(["pkg", "publisher", "-Ftsv"])
    if res.rc != 0:
        fail("failed to list publishers: " + res.stderr)

    # Parse output
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        fail("no publishers output from pkg publisher")
    keys = lines[0].lower().split("\t")
    publishers = {}
    for line in lines[1:]:
        if line.strip() == "":
            continue
        values = dict(zip(keys, _unstringify_list(line.split("\t"))))
        pub_name = values["publisher"]
        if pub_name not in publishers:
            publishers[pub_name] = {
                "sticky": values["sticky"],
                "enabled": values["enabled"],
                "origin": [],
                "mirror": [],
            }
        if values["type"] != None and values["type"] in ["origin", "mirror"]:
            publishers[pub_name][values["type"]].append(values["uri"])

    # Handle absent state
    if state == "absent":
        if name not in publishers:
            return {"changed": False, "msg": "publisher " + name + " is not present"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove publisher " + name}
        res = ctx.run(["pkg", "unset-publisher", name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove publisher " + name}
        if res.rc != 0:
            fail("failed to unset publisher " + name + ": " + res.stderr)
        return {"changed": True, "msg": "removed publisher " + name}

    # Handle present state
    if name not in publishers:
        # New publisher
        if ctx.check_mode:
            return {"changed": True, "msg": "would add publisher " + name}
        args = []
        if origin != None:
            args.append("--remove-origin=*")
            args.extend(["--add-origin=" + u for u in origin])
        if mirror != None:
            args.append("--remove-mirror=*")
            args.extend(["--add-mirror=" + u for u in mirror])
        if sticky != None:
            if sticky:
                args.append("--sticky")
            else:
                args.append("--non-sticky")
        if enabled != None:
            if enabled:
                args.append("--enable")
            else:
                args.append("--disable")
        res = ctx.run(["pkg", "set-publisher"] + args + [name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would add publisher " + name}
        if res.rc != 0:
            fail("failed to set publisher " + name + ": " + res.stderr)
        return {"changed": True, "msg": "added publisher " + name}

    # Existing publisher - check if any changes needed
    existing = publishers[name]
    if _dicts_equal(origin, existing.get("origin")) and \
       _dicts_equal(mirror, existing.get("mirror")) and \
       (sticky == None or sticky == existing.get("sticky")) and \
       (enabled == None or enabled == existing.get("enabled")):
        return {"changed": False, "msg": "publisher " + name + " is already correct"}

    # Changes needed
    if ctx.check_mode:
        return {"changed": True, "msg": "would update publisher " + name}

    args = []
    if origin != None:
        args.append("--remove-origin=*")
        args.extend(["--add-origin=" + u for u in origin])
    if mirror != None:
        args.append("--remove-mirror=*")
        args.extend(["--add-mirror=" + u for u in mirror])
    if sticky != None:
        if sticky:
            args.append("--sticky")
        else:
            args.append("--non-sticky")
    if enabled != None:
        if enabled:
            args.append("--enable")
        else:
            args.append("--disable")
    res = ctx.run(["pkg", "set-publisher"] + args + [name], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would update publisher " + name}
    if res.rc != 0:
        fail("failed to update publisher " + name + ": " + res.stderr)
    return {"changed": True, "msg": "updated publisher " + name}


def _unstringify(val):
    if val == "-" or val == "":
        return None
    elif val == "true":
        return True
    elif val == "false":
        return False
    else:
        return val


def _unstringify_list(vals):
    return [_unstringify(v) for v in vals]


def _dicts_equal(new_list, existing_list):
    if new_list == None:
        return True
    if type(new_list) != "list" or type(existing_list) != "list":
        return False
    if len(new_list) != len(existing_list):
        return False
    for i in range(len(new_list)):
        if new_list[i] != existing_list[i]:
            return False
    return True
