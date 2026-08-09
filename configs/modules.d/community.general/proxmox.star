def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")

    # Authentication: fail if neither password nor token provided
    has_password = api_password != None
    has_token = api_token_id != None and api_token_secret != None
    if not (has_password or has_token):
        fail("one of api_password or api_token_id+api_token_secret must be provided")

    # Basic state checks
    state = params.get("state", "present")
    vmid = params.get("vmid")
    hostname = params.get("hostname")

    # Determine VZ_TYPE: assume LXC (PVE >= 4) — cannot query PVE version via ctx; fail on openvz only
    vz_type = "lxc"

    # vmid resolution: try to get it from hostname if not given
    if vmid == None and state == "present" and hostname != None:
        # Attempt to discover VM ID by hostname via API — we simulate this with a run
        # In real usage, this would call an endpoint; here we must simulate discovery via CLI or API
        # Since there's no CLI for VM ID lookup by hostname in Proxmox, we rely on external help or skip
        fail("vmid must be provided or discovered; discovery by hostname is not implemented in starlark runtime")

    if vmid == None:
        fail("vmid is required for all operations in this starlark translation")

    # State handling
    if state == "absent":
        # Check if VM exists
        res = ctx.run(
            ["curl", "-sk", "-X", "GET",
             "-H", "Authorization: PVEAPIToken=" + api_user + "!" + api_token_id + "=" + api_token_secret if has_token else "-u " + api_user + ":" + api_password,
             "https://" + api_host + ":8006/api2/json/nodes/-/" + vz_type + "/" + str(vmid)],
            mutates=False
        )
        # If response contains "vmid" or is 200 OK, it exists; we simplify by checking rc == 0 and non-empty body
        exists = res.rc == 0 and ("vmid" in res.stdout or "data" in res.stdout)
        if not exists:
            return {"changed": False, "msg": "VM %s does not exist" % vmid}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove VM %s" % vmid}
        # Delete VM
        res = ctx.run(
            ["curl", "-sk", "-X", "DELETE",
             "-H", "Authorization: PVEAPIToken=" + api_user + "!" + api_token_id + "=" + api_token_secret if has_token else "-u " + api_user + ":" + api_password,
             "https://" + api_host + ":8006/api2/json/nodes/-/" + vz_type + "/" + str(vmid)],
            mutates=True
        )
        if res.rc != 0:
            fail("failed to delete VM %s: %s" % (vmid, res.stderr))
        return {"changed": True, "msg": "removed VM %s" % vmid}

    if state == "present":
        # Create or update VM
        # We don't implement full create/update due to complexity (clone, template, storage, etc.)
        # Instead, fail on unsupported features or outline only
        if params.get("clone") != None:
            fail("clone operation is not supported in this starlark translation")
        if params.get("ostemplate") == None and params.get("update") != True:
            fail("ostemplate is required for VM creation")
        if ctx.check_mode:
            return {"changed": True, "msg": "would create or update VM %s" % vmid}
        # Attempt to create/update VM via curl (simplified)
        # In practice, this would need full payload construction; omitted for brevity
        fail("VM creation/update is not fully implemented in starlark runtime; consider using Ansible module directly")
        # Placeholder return
        return {"changed": True, "msg": "VM %s created" % vmid}

    # Other states — not fully implemented due to scope
    if state in ["started", "stopped", "restarted", "template"]:
        fail("state %s is not supported in this starlark translation" % state)

    fail("unsupported state: " + state)
