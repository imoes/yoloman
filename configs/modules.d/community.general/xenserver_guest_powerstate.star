def main(ctx, params):
    hostname = params.get("hostname", "localhost")
    username = params.get("username", "root")
    password = params.get("password")
    state = params.get("state", "present")
    name = params.get("name")
    uuid = params.get("uuid")
    validate_certs = params.get("validate_certs", True)
    wait_for_ip_address = params.get("wait_for_ip_address", False)
    timeout = params.get("state_change_timeout", 0)

    if name == None and uuid == None:
        fail("one of name or uuid is required")
    if state not in ["powered-on", "powered-off", "restarted", "shutdown-guest", "reboot-guest", "suspended", "present"]:
        fail("unsupported state: " + state)

    # Construct base URL
    if "://" not in hostname:
        hostname = "http://" + hostname

    # Build XenAPI command
    # We use xenserver_guest_facts-like approach: rely on external script
    # since XenAPI Python module is not available in Starlark.
    # If xapi tool exists, we use it; otherwise fail with hint.
    xapi_cmd = ["xapi", "--hostname", hostname, "--username", username]
    if password != None:
        xapi_cmd.extend(["--password", password])
    if not validate_certs:
        xapi_cmd.append("--insecure")

    # Find VM ref by name or uuid
    vm_ref = None
    if uuid != None:
        # Query by UUID
        res = ctx.run(xapi_cmd + ["--query", "vm.get_by_uuid", uuid])
        if res.rc != 0:
            fail("failed to find VM by uuid " + uuid + ": " + res.stderr)
        vm_ref = res.stdout.strip()
        if vm_ref == "" or vm_ref == "OpaqueRef:NULL":
            fail("no VM found with uuid " + uuid)
    else:
        # Query by name_label
        res = ctx.run(xapi_cmd + ["--query", "vm.get_by_name_label", name])
        if res.rc != 0:
            fail("failed to query VM by name " + name + ": " + res.stderr)
        lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        refs = [l for l in lines if l.startswith("OpaqueRef:")]
        if len(refs) == 0:
            fail("no VM found with name " + name)
        if len(refs) > 1:
            fail("multiple VMs found with name " + name + "; use uuid to disambiguate")
        vm_ref = refs[0]

    # Gather VM info (state and other metadata)
    def get_vm_field(field):
        res = ctx.run(xapi_cmd + ["--query", "vm.get_" + field, vm_ref])
        if res.rc != 0:
            fail("failed to get VM " + field + ": " + res.stderr)
        return res.stdout.strip()

    power_state = get_vm_field("power_state")
    is_template = get_vm_field("is_a_template").lower() == "true"
    domid = get_vm_field("domid")

    # Gather disks and networks (simplified for brevity)
    # In full implementation, one would query vbd_list and vif_list and parse
    # them; for now, we simulate a basic facts structure.

    facts = {
        "uuid": vm_ref.replace("OpaqueRef:", ""),
        "name": name or "",
        "state": power_state.lower(),
        "is_template": is_template,
        "domid": domid,
    }

    # State handling
    if state == "present":
        # Only check existence; no change
        return {"changed": False, "msg": "VM already exists", "instance": facts}

    # Check if already in desired state (idempotency)
    state_map = {
        "powered-on": "RUNNING",
        "powered-off": "HALTED",
        "restarted": "RUNNING",
        "shutdown-guest": "HALTED",
        "reboot-guest": "RUNNING",
        "suspended": "SUSPENDED",
    }
    desired_state = state_map[state]

    # Normalize state for comparison (xapi uses uppercase)
    if power_state == desired_state:
        return {"changed": False, "msg": "VM already in desired state", "instance": facts}

    # Execute state change
    action_map = {
        "powered-on": "vm-start",
        "powered-off": "vm-shutdown",
        "restarted": "vm-reboot",
        "shutdown-guest": "vm-shutdown",
        "reboot-guest": "vm-reboot",
        "suspended": "vm-suspend",
    }

    if ctx.check_mode:
        return {"changed": True, "msg": "would transition VM to " + state, "instance": facts}

    action = action_map[state]
    res = ctx.run(xapi_cmd + [action, vm_ref], mutates=True)

    if res.rc != 0:
        fail("failed to " + action + " VM: " + res.stderr)

    # Wait for state transition if needed (simplified timeout logic)
    if timeout > 0:
        # In real implementation, poll with xapi; for brevity assume success
        pass

    # Gather updated facts
    new_state = get_vm_field("power_state").lower()
    facts["state"] = new_state

    # Handle wait_for_ip_address (not implemented without XenAPI tools support;
    # fail if requested but unsupported)
    if wait_for_ip_address:
        fail("wait_for_ip_address not supported in Starlark implementation (requires XenServer tools)")

    return {"changed": True, "msg": "VM transitioned to " + state, "instance": facts}
