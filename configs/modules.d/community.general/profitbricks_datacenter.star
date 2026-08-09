def main(ctx, params):
    # Required params
    name = params.get("name")
    if name == None:
        fail("name parameter is required")
    subscription_user = params.get("subscription_user")
    if subscription_user == None:
        fail("subscription_user parameter is required")
    subscription_password = params.get("subscription_password")
    if subscription_password == None:
        fail("subscription_password parameter is required")

    # Optional params with defaults
    description = params.get("description")
    location = params.get("location", "us/las")
    wait = params.get("wait", True)
    wait_timeout = int(params.get("wait_timeout", 600))
    state = params.get("state", "present")

    # Validate location
    valid_locations = ["us/las", "de/fra", "de/fkb"]
    if location not in valid_locations:
        fail("invalid location '%s'; must be one of: %s" % (location, ", ".join(valid_locations)))

    # Check if pb CLI is available
    check_res = ctx.run(["which", "pb"], mutates=False)
    if check_res.rc != 0:
        fail("profitbricks CLI (pb) is required for this module")

    if state == "absent":
        # Find datacenter ID by name
        found_id = None
        list_res = ctx.run(["pb", "datacenter", "list", "--format", "csv"], mutates=False)
        if list_res.rc != 0:
            fail("failed to list datacenters: " + list_res.stderr)
        lines = list_res.stdout.split("\n")
        for line in lines:
            if line == "":
                continue
            parts = line.split(",")
            if len(parts) >= 2:
                dc_id = parts[0]
                dc_name = parts[1].strip('"').strip()
                if dc_name == name:
                    found_id = dc_id
                    break
        if found_id == None:
            return {"changed": False, "msg": "datacenter '%s' not found" % name}

        if ctx.check_mode:
            return {"changed": True, "msg": "would remove datacenter '%s' (%s)" % (name, found_id)}

        delete_res = ctx.run(["pb", "datacenter", "delete", "--id", found_id], mutates=True)
        if delete_res.rc != 0:
            fail("failed to delete datacenter: " + delete_res.stderr)

        if wait:
            elapsed = 0
            while elapsed < wait_timeout:
                show_res = ctx.run(["pb", "datacenter", "show", "--id", found_id], mutates=False)
                if show_res.rc != 0:
                    break
                # Simulate sleep without importing time (use ctx.run sleep command)
                sleep_res = ctx.run(["sleep", "5"], mutates=False)
                elapsed += 5
            if elapsed >= wait_timeout:
                fail("timed out waiting for datacenter deletion")

        return {"changed": True, "msg": "datacenter '%s' removed" % name}

    elif state == "present":
        # Check if exists
        exists_id = None
        list_res = ctx.run(["pb", "datacenter", "list", "--format", "csv"], mutates=False)
        if list_res.rc != 0:
            fail("failed to list datacenters: " + list_res.stderr)
        lines = list_res.stdout.split("\n")
        for line in lines:
            if line == "":
                continue
            parts = line.split(",")
            if len(parts) >= 2:
                dc_id = parts[0]
                dc_name = parts[1].strip('"').strip()
                if dc_name == name:
                    exists_id = dc_id
                    break

        if exists_id != None:
            if ctx.check_mode:
                return {"changed": False, "msg": "datacenter '%s' already exists" % name}
            return {"changed": False, "msg": "datacenter '%s' already exists" % name}

        # Prepare create args
        cmd = ["pb", "datacenter", "create", "--name", name, "--location", location]
        if description != None:
            cmd.extend(["--description", description])

        if ctx.check_mode:
            return {"changed": True, "msg": "would create datacenter '%s'" % name}

        create_res = ctx.run(cmd, mutates=True)
        if create_res.rc != 0:
            fail("failed to create datacenter: " + create_res.stderr)

        # Extract ID from stdout
        output = create_res.stdout.strip()
        if output == "":
            fail("failed to parse datacenter ID from creation output")
        created_id = output.split("\n")[-1].strip()

        if wait:
            elapsed = 0
            while elapsed < wait_timeout:
                show_res = ctx.run(["pb", "datacenter", "show", "--id", created_id], mutates=False)
                if show_res.rc == 0:
                    break
                sleep_res = ctx.run(["sleep", "5"], mutates=False)
                elapsed += 5
            if elapsed >= wait_timeout:
                fail("timed out waiting for datacenter creation")

        return {"changed": True, "msg": "datacenter '%s' created" % name, "datacenter_id": created_id}

    fail("unsupported state: " + state)
