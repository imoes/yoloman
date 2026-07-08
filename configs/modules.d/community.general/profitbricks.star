def main(ctx, params):
    state = params.get("state", "present")
    if state not in ("present", "absent", "running", "stopped"):
        ctx.fail("unsupported state: " + state)
    if state != "present" and not params.get("datacenter"):
        ctx.fail("datacenter parameter is required for " + state)
    if state == "present":
        if not params.get("name"):
            ctx.fail("name parameter is required for new instance")
        if not params.get("image"):
            ctx.fail("image parameter is required for new instance")

    cmd = ["pb"]
    if params.get("subscription_user"):
        cmd.extend(["--username", str(params["subscription_user"])])
    if params.get("subscription_password"):
        cmd.extend(["--password", str(params["subscription_password"])])
    if params.get("location"):
        cmd.extend(["--location", str(params["location"])])
    if params.get("datacenter"):
        cmd.extend(["--datacenter", str(params["datacenter"])])
    if params.get("name"):
        cmd.extend(["--name", str(params["name"])])
    if params.get("image"):
        cmd.extend(["--image", str(params["image"])])
    if params.get("cores"):
        cmd.extend(["--cores", str(params["cores"])])
    if params.get("ram"):
        cmd.extend(["--ram", str(params["ram"])])
    if params.get("cpu_family"):
        cmd.extend(["--cpu-family", str(params["cpu_family"])])
    if params.get("volume_size"):
        cmd.extend(["--volume-size", str(params["volume_size"])])
    if params.get("disk_type"):
        cmd.extend(["--disk-type", str(params["disk_type"])])
    if params.get("bus"):
        cmd.extend(["--bus", str(params["bus"])])
    if params.get("lan"):
        cmd.extend(["--lan", str(params["lan"])])
    if params.get("assign_public_ip"):
        cmd.append("--assign-public-ip")
    if params.get("auto_increment"):
        cmd.append("--auto-increment")
    if params.get("count"):
        cmd.extend(["--count", str(params["count"])])
    if params.get("remove_boot_volume"):
        cmd.append("--remove-boot-volume")
    if params.get("wait"):
        cmd.append("--wait")
    if params.get("wait_timeout"):
        cmd.extend(["--wait-timeout", str(params["wait_timeout"])])

    if state == "absent":
        ids = params.get("instance_ids", [])
        if not isinstance(ids, list) or len(ids) == 0:
            ctx.fail("instance_ids should be a list of virtual machine ids or names")
        for i in ids:
            res = ctx.run(cmd + ["server", "delete", "--server-id", str(i)])
            if res.rc != 0:
                ctx.fail("failed to delete server " + str(i) + ": " + res.stderr)
        return {"changed": True, "msg": "instances removed"}
    elif state == "running":
        ids = params.get("instance_ids", [])
        if not isinstance(ids, list) or len(ids) == 0:
            ctx.fail("instance_ids should be a list of virtual machine ids or names")
        for i in ids:
            res = ctx.run(cmd + ["server", "start", "--server-id", str(i)])
            if res.rc != 0:
                ctx.fail("failed to start server " + str(i) + ": " + res.stderr)
        return {"changed": True, "msg": "instances started"}
    elif state == "stopped":
        ids = params.get("instance_ids", [])
        if not isinstance(ids, list) or len(ids) == 0:
            ctx.fail("instance_ids should be a list of virtual machine ids or names")
        for i in ids:
            res = ctx.run(cmd + ["server", "stop", "--server-id", str(i)])
            if res.rc != 0:
                ctx.fail("failed to stop server " + str(i) + ": " + res.stderr)
        return {"changed": True, "msg": "instances stopped"}
    else:
        list_res = ctx.run(cmd + ["server", "list"])
        if list_res.rc != 0:
            ctx.fail("failed to list servers: " + list_res.stderr)
        existing_names = []
        for line in list_res.stdout.split("\n"):
            parts = line.strip().split()
            if len(parts) >= 2:
                existing_names.append(parts[1])
        desired_names = []
        auto_inc = params.get("auto_increment", True)
        count = params.get("count", 1)
        if auto_inc:
            base = params["name"]
            for i in range(count):
                fmt_str = base.replace("%d", "%02d") if "%d" in base else base + "%d"
                desired_names.append(fmt_str % (i + 1))
        else:
            desired_names = [params["name"]]
        changed = False
        for name in desired_names:
            if name in existing_names:
                continue
            create_res = ctx.run(cmd + ["server", "create"], mutates=True)
            if create_res.rc != 0:
                ctx.fail("failed to create server " + name + ": " + create_res.stderr)
            changed = True
        return {"changed": changed, "msg": "instances created" if changed else "instances already exist"}
