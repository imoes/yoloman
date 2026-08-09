def main(ctx, params):
    # Map Ansible state to vmadm action state
    state_map = {
        "present": "running",
        "running": "running",
        "absent": "deleted",
        "deleted": "deleted",
        "stopped": "stopped",
        "created": "stopped",
        "restarted": "rebooted",
        "rebooted": "rebooted"
    }

    state = params.get("state", "running")
    vm_state = state_map.get(state)
    if vm_state == None:
        fail("unsupported state: " + state)

    # Get VM identifier: prefer uuid, fallback to name/alias
    uuid = params.get("uuid")
    name = params.get("name")

    if uuid == None and name == None:
        fail("one of 'uuid' or 'name' is required")

    # If uuid is not provided, look it up by name
    if uuid == None:
        res = ctx.run(["vmadm", "lookup", "-j", "-o", "uuid", "alias=" + name])
        if res.rc != 0:
            fail("could not look up VM by alias '" + name + "': " + res.stderr)
        parsed = res.stdout.strip()
        if parsed == "":
            uuid = None
        else:
            uuid = parsed

    # Handle wildcard for all VMs
    if uuid == "*":
        # Only state transitions supported for all VMs
        if state in ["created"]:
            fail("state 'created' is only valid for tasks with a single VM")

        all_uuids_res = ctx.run(["vmadm", "lookup", "-j", "-o", "uuid"])
        if all_uuids_res.rc != 0:
            fail("failed to list VMs: " + all_uuids_res.stderr)
        all_uuids = [u.strip() for u in all_uuids_res.stdout.strip().split("\n") if u.strip() != ""]

        changed = False
        for u in all_uuids:
            curr_res = ctx.run(["vmadm", "lookup", "-j", "-o", "state", "uuid=" + u])
            if curr_res.rc != 0:
                fail("failed to get state for VM " + u + ": " + curr_res.stderr)
            curr_state = curr_res.stdout.strip()
            if ctx.check_mode:
                if curr_state != vm_state:
                    changed = True
            else:
                ret = set_vm_state(ctx, u, vm_state, params.get("force", False))
                if ret == None:
                    pass
                elif ret == True:
                    changed = True
                else:
                    fail("failed to set VM " + u + " to state " + vm_state)

        return {"changed": changed, "msg": "processed all VMs", "state": state, "uuid": "*" }

    # Get current state of the VM
    curr_state = None
    if uuid != None:
        curr_res = ctx.run(["vmadm", "lookup", "-j", "-o", "state", "uuid=" + uuid])
        if curr_res.rc == 0:
            curr_state = curr_res.stdout.strip()

    # Handle special case: deleted but VM doesn't exist
    if vm_state == "deleted" and curr_state == None:
        return {"changed": False, "msg": "VM already absent", "state": state, "uuid": uuid, "name": name if name != None else ""}

    # Handle check_mode
    if ctx.check_mode:
        if curr_state == None and vm_state != "deleted":
            changed = True
        elif curr_state != vm_state:
            changed = True
        else:
            changed = False
        return {"changed": changed, "msg": "would " + ("create and " if curr_state == None else "") + ("set to " + vm_state if curr_state != vm_state else "already " + vm_state), "state": state, "uuid": uuid, "name": name if name != None else ""}

    # No VM found -> create
    if curr_state == None and vm_state != "deleted":
        payload_file = create_payload(ctx, params)
        res = ctx.run(["vmadm", "create", "-f", payload_file])
        if res.rc != 0:
            # Cleanup payload on failure
            ctx.run(["rm", "-f", payload_file])
            fail("could not create VM: " + res.stderr)

        # Parse new UUID from stderr (vmadm create outputs to stderr)
        uuid_match = None
        for line in res.stderr.split("\n"):
            if line.startswith("Successfully created VM "):
                uuid_match = line.split(" ")[-1].strip()
                break

        if uuid_match == None:
            ctx.run(["rm", "-f", payload_file])
            fail("could not parse UUID from vmadm create output: " + res.stderr)

        uuid = uuid_match

        # Clean up payload file
        ctx.run(["rm", "-f", payload_file])

        # If not 'running', set state
        if vm_state != "running":
            ret = set_vm_state(ctx, uuid, vm_state, params.get("force", False))
            if ret == None:
                pass
            elif ret == True:
                pass
            else:
                fail("failed to set VM " + uuid + " to state " + vm_state)

        return {"changed": True, "msg": "created VM " + uuid, "state": state, "uuid": uuid, "name": name if name != None else ""}

    # VM exists -> operate on state
    ret = set_vm_state(ctx, uuid, vm_state, params.get("force", False))
    if ret == None:
        return {"changed": False, "msg": "VM already in desired state " + vm_state, "state": state, "uuid": uuid, "name": name if name != None else ""}
    elif ret == True:
        return {"changed": True, "msg": "set VM " + uuid + " to state " + vm_state, "state": state, "uuid": uuid, "name": name if name != None else ""}
    else:
        fail("failed to set VM " + uuid + " to state " + vm_state)


def set_vm_state(ctx, uuid, vm_state, force):
    cmds = {
        "stopped": ["stop", True],
        "running": ["start", False],
        "deleted": ["delete", True],
        "rebooted": ["reboot", False]
    }

    if not vm_state in cmds:
        fail("unsupported vm_state: " + vm_state)

    command, forceable = cmds[vm_state]
    force_flag = ["-F"] if force and forceable else []

    res = ctx.run(["vmadm", command] + force_flag + [uuid])
    if res.rc != 0:
        return False

    # Check success message
    for line in res.stderr.split("\n"):
        if line.startswith("Successfully"):
            return True

    return None


def create_payload(ctx, params):
    # Filter out non-vmadm options
    skip_keys = ["state", "name", "alias", "uuid", "force", "check_mode"]
    vmdef = {}
    for k in params.keys():
        if not k in skip_keys and params.get(k) != None:
            vmdef[k] = params.get(k)

    # Convert Python dict to JSON manually
    def to_json(obj):
        if type(obj) == "dict":
            parts = []
            for k in sorted(obj.keys()):
                parts.append('"' + k + '":' + to_json(obj[k]))
            return "{" + ",".join(parts) + "}"
        elif type(obj) == "list":
            return "[" + ",".join([to_json(x) for x in obj]) + "]"
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int":
            return str(obj)
        elif type(obj) == "string":
            # Simple JSON escaping for string
            escaped = str(obj).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
            return '"' + escaped + '"'
        elif obj == None:
            return "null"
        else:
            fail("unsupported type in JSON: " + str(type(obj)))

    json_str = to_json(vmdef)

    # Write to temp file
    tmp_file = "/tmp/vmadm-payload-" + str(ctx.facts().get("hostname", "host")) + "-" + str(hash(json_str) % 10000) + ".json"
    changed = ctx.file_write(tmp_file, json_str + "\n", "0400")

    # In check_mode, ctx.file_write returns False if no change; still need valid path
    if ctx.check_mode and not changed:
        # Create a dummy file to avoid failures in check mode
        ctx.run(["touch", tmp_file])

    return tmp_file
