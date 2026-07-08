def main(ctx, params):
    # Required parameters validation
    state = params.get("state", "present")
    if state != "present" and state != "absent":
        fail("state must be 'present' or 'absent'")

    name = params.get("name")
    flavor = params.get("flavor")
    image = params.get("image")
    group = params.get("group")

    # For present state, require name, flavor, and either image or boot_volume
    if state == "present":
        if not name:
            fail("name is required when state=present")
        if not flavor:
            fail("flavor is required when state=present")
        if not image and not params.get("boot_volume"):
            fail("image or boot_volume is required when state=present")

    # Read existing servers by group if group is specified
    servers = []
    if group:
        res = ctx.run(["rax", "servers", "list", "--group", group, "--format", "json"])
        if res.rc == 0:
            lines = res.stdout.strip().split("\n")
            for line in lines:
                if line.startswith("{"):
                    servers.append(line)
        elif res.rc == 127:
            fail("rax CLI not found — please install rackspace-cli or use custom logic")
        else:
            fail("Failed to list servers: " + res.stderr)

    if state == "absent":
        instance_ids = params.get("instance_ids", [])
        count = params.get("count", 1)

        to_delete = []
        if len(instance_ids) > 0:
            to_delete = instance_ids
        elif group and len(servers) > 0:
            to_delete = servers[:min(count, len(servers))]
        else:
            return {"changed": False, "msg": "No instances to delete"}

        changed = False
        for sid in to_delete:
            res = ctx.run(["rax", "servers", "delete", sid], mutates=True)
            if res.rc != 0:
                fail("Failed to delete server " + sid + ": " + res.stderr)
            changed = True

        if ctx.check_mode and len(to_delete) > 0:
            return {"changed": True, "msg": "would delete " + str(len(to_delete)) + " instances"}
        return {"changed": changed, "msg": "deleted " + str(len(to_delete)) + " instances"}

    # state == "present"
    auto_increment = params.get("auto_increment", True)
    count = params.get("count", 1)
    count_offset = params.get("count_offset", 1)
    exact_count = params.get("exact_count", False)

    if exact_count and group:
        current_count = len(servers)
        diff = current_count - count
        if diff > 0:
            to_delete = servers[:diff]
            for sid in to_delete:
                res = ctx.run(["rax", "servers", "delete", sid], mutates=True)
                if res.rc != 0:
                    fail("Failed to delete excess server " + sid + ": " + res.stderr)
            servers = servers[diff:]
            count = 0
        elif diff < 0:
            count = -diff
        else:
            return {"changed": False, "msg": "exact_count already satisfied"}

    names_to_create = []
    if auto_increment and group and count > 0:
        if name.find("%") == -1:
            name = name + "%d"
        for i in range(count_offset, count_offset + count):
            names_to_create.append(name % i)
    elif not auto_increment or not group:
        for _ in range(count):
            names_to_create.append(name)

    if len(names_to_create) == 0 and len(servers) >= count:
        return {"changed": False, "msg": "already have " + str(len(servers)) + " servers"}

    created = []
    for nm in names_to_create:
        args = ["rax", "servers", "create", nm, "--flavor", flavor]
        if image:
            args.extend(["--image", image])
        if group:
            args.extend(["--meta", "group=" + group])
        if params.get("key_name"):
            args.extend(["--key-name", params["key_name"]])
        if params.get("user_data"):
            args.extend(["--user-data", params["user_data"]])
        if params.get("config_drive"):
            args.append("--config-drive")
        if params.get("boot_from_volume"):
            args.append("--boot-from-volume")
        if params.get("boot_volume"):
            args.extend(["--boot-volume", params["boot_volume"]])
        if params.get("boot_volume_size"):
            args.extend(["--boot-volume-size", str(params["boot_volume_size"])])
        res = ctx.run(args, mutates=True)
        if res.rc != 0:
            fail("Failed to create server " + nm + ": " + res.stderr)
        created.append("simulated-id-" + nm)

    if ctx.check_mode and len(names_to_create) > 0:
        return {"changed": True, "msg": "would create " + str(len(names_to_create)) + " instances"}

    msg = "created " + str(len(created)) + " instances"
    if len(created) > 0:
        msg = msg + ": "
        for i in range(min(3, len(created))):
            if i > 0:
                msg = msg + ", "
            msg = msg + created[i]
        if len(created) > 3:
            msg = msg + " ..."
    return {"changed": len(created) > 0, "msg": msg}
