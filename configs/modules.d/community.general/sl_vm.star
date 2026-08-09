def main(ctx, params):
    state = params.get("state", "present")
    instance_id = params.get("instance_id")
    hostname = params.get("hostname")
    domain = params.get("domain")
    datacenter = params.get("datacenter")
    tags = params.get("tags")
    hourly = params.get("hourly", True)
    private = params.get("private", False)
    dedicated = params.get("dedicated", False)
    local_disk = params.get("local_disk", True)
    cpus = params.get("cpus")
    memory = params.get("memory")
    flavor = params.get("flavor")
    disks = params.get("disks", [25])
    os_code = params.get("os_code")
    image_id = params.get("image_id")
    nic_speed = params.get("nic_speed")
    public_vlan = params.get("public_vlan")
    private_vlan = params.get("private_vlan")
    ssh_keys = params.get("ssh_keys", [])
    post_uri = params.get("post_uri")
    wait = params.get("wait", True)
    wait_time = params.get("wait_time", 600)

    # Validate required arguments for creation
    if state == "present":
        if hostname == None or domain == None:
            fail("hostname and domain are required when state is present")
        if (os_code == None or os_code == "") and (image_id == None or image_id == ""):
            fail("either os_code or image_id is required when state is present")
        if flavor == None and (cpus == None or memory == None):
            fail("either flavor or both cpus and memory must be provided")

    # Build base command
    argv = ["sl_vm", "--format=json"]

    if state == "absent":
        if instance_id != None:
            argv.extend(["cancel", "--instance-id", str(instance_id)])
        elif tags != None:
            # Convert list to comma-separated string if needed
            if type(tags) == "list":
                tags = ",".join([str(t) for t in tags])
            argv.extend(["cancel", "--tags", tags])
        elif hostname != None:
            argv.extend(["cancel", "--hostname", str(hostname)])
            if domain != None:
                argv.extend(["--domain", str(domain)])
        else:
            return {"changed": False, "msg": "no criteria provided to cancel instance"}

        res = ctx.run(argv)
        if res.rc != 0:
            fail("failed to cancel instance: " + res.stderr)
        return {"changed": True, "msg": "instance cancelled"}

    elif state == "present":
        # Check for existing instance by hostname+domain+datacenter (basic check)
        list_argv = ["sl_vm", "list", "--hostname", str(hostname), "--domain", str(domain), "--format=json"]
        if datacenter != None:
            list_argv.extend(["--datacenter", str(datacenter)])
        list_res = ctx.run(list_argv)
        if list_res.rc == 0 and list_res.stdout.strip() != "":
            # Simple JSON parse without try/except: look for "id" in output
            stdout = list_res.stdout.strip()
            # Try basic detection of list with items
            if "[{" in stdout or '{"' in stdout:
                return {"changed": False, "msg": "instance already exists"}

        # Build create command
        create_argv = ["sl_vm", "create"]

        # Required args
        create_argv.extend(["--hostname", str(hostname)])
        create_argv.extend(["--domain", str(domain)])

        # Optional flags
        if datacenter != None:
            create_argv.extend(["--datacenter", str(datacenter)])
        if hourly == False:
            create_argv.append("--hourly=false")
        if private == True:
            create_argv.append("--private")
        if dedicated == True:
            create_argv.append("--dedicated")
        if local_disk == False:
            create_argv.append("--local-disk=false")

        # Resource specs
        if flavor != None:
            create_argv.extend(["--flavor", str(flavor)])
        else:
            create_argv.extend(["--cpus", str(cpus)])
            create_argv.extend(["--memory", str(memory)])

        # Disk spec
        if type(disks) == "list" and len(disks) > 0:
            disk_str = ",".join([str(d) for d in disks])
            create_argv.extend(["--disks", disk_str])

        # Image / OS
        if os_code != None and os_code != "":
            create_argv.extend(["--os", str(os_code)])
        elif image_id != None and image_id != "":
            create_argv.extend(["--image-id", str(image_id)])
            # Skip disks for image-based provisioning
            # disks arg already added; we rely on API to ignore for templates

        # Network
        if nic_speed != None:
            create_argv.extend(["--nic-speed", str(nic_speed)])
        if public_vlan != None:
            create_argv.extend(["--public-vlan", str(public_vlan)])
        if private_vlan != None:
            create_argv.extend(["--private-vlan", str(private_vlan)])

        # Auth
        if type(ssh_keys) == "list" and len(ssh_keys) > 0:
            key_ids = ",".join([str(k) for k in ssh_keys])
            create_argv.extend(["--ssh-keys", key_ids])

        # Post script
        if post_uri != None:
            create_argv.extend(["--post-uri", str(post_uri)])

        # Tags
        if tags != None:
            if type(tags) == "list":
                tags = ",".join([str(t) for t in tags])
            create_argv.extend(["--tags", tags])

        res = ctx.run(create_argv, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create virtual instance"}
        if res.rc != 0:
            fail("failed to create instance: " + res.stderr)

        # Parse ID from stdout (assume JSON output with "id" field)
        instance_id_created = None
        stdout = res.stdout.strip()
        # Simple heuristic to find id field
        lines = stdout.split("\n")
        for line in lines:
            line_lower = line.lower()
            if '"id"' in line_lower or "'id'" in line_lower:
                # Extract value between quotes or colons
                for sep in [':', ': ']:
                    if sep in line:
                        val_part = line.split(sep, 1)[1].strip().strip('"').strip("'")
                        if val_part.isdigit():
                            instance_id_created = val_part
                            break
            if instance_id_created != None:
                break

        if instance_id_created == None:
            fail("could not parse instance id from creation response")

        # Wait for ready if requested
        if wait == True:
            # Simulate polling via sl_vm status command
            elapsed = 0
            while elapsed < wait_time:
                status_argv = ["sl_vm", "status", "--instance-id", instance_id_created, "--format=json"]
                status_res = ctx.run(status_argv)
                if status_res.rc == 0:
                    status_stdout = status_res.stdout.strip()
                    if '"status"' in status_stdout or "'status'" in status_stdout:
                        if '"status": "RUNNING"' in status_stdout or '"status": "ACTIVE"' in status_stdout:
                            return {"changed": True, "msg": "instance created and active"}
                        if "'status': 'RUNNING'" in status_stdout or "'status': 'ACTIVE'" in status_stdout:
                            return {"changed": True, "msg": "instance created and active"}
                # Wait 5 seconds before next poll
                # Use ctx.run with a dummy command to sleep
                sleep_res = ctx.run(["sleep", "5"])
                elapsed = elapsed + 5

            fail("waited %d seconds but instance did not become active" % wait_time)

        return {"changed": True, "msg": "instance created"}
    else:
        fail("unsupported state: " + str(state))
