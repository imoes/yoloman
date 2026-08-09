def main(ctx, params):
    # Required params
    api_host = params["api_host"]
    api_user = params["api_user"]
    interface = params["interface"]
    state = params.get("state", "present")
    
    # Optional params with defaults
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    bridge = params.get("bridge")
    firewall = params.get("firewall", False)
    link_down = params.get("link_down", False)
    mac = params.get("mac")
    model = params.get("model", "virtio")
    mtu = params.get("mtu")
    name = params.get("name")
    queues = params.get("queues")
    rate = params.get("rate")
    tag = params.get("tag")
    trunks = params.get("trunks")
    vmid = params.get("vmid")
    validate_certs = params.get("validate_certs", False)
    
    # Validate required combinations
    if vmid == None and name == None:
        fail("one of vmid or name is required")
    if api_password == None and api_token_id == None:
        fail("one of api_password or api_token_id is required")
    if api_token_id != None and api_token_secret == None:
        fail("api_token_secret is required when using api_token_id")
    if api_token_secret != None and api_token_id == None:
        fail("api_token_id is required when using api_token_secret")

    # Get vmid by name if not provided
    if vmid == None:
        fail("vmid not provided and name lookup requires full API implementation - use vmid instead")

    # Validate interface name format: net[n] where 1 <= n <= 31
    if not interface.startswith("net") or not interface[3:].isdigit() or len(interface) != 4:
        fail("interface must be in format 'net[n]' where 1 <= n <= 31")
    nic_num = int(interface[3:])
    if nic_num < 1 or nic_num > 31:
        fail("interface number must be between 1 and 31")

    # Build config string for the NIC
    config_provided = model
    if mac != None:
        config_provided += "=" + mac
    
    if bridge != None:
        config_provided += ",bridge=" + bridge
    if firewall:
        config_provided += ",firewall=1"
    if link_down:
        config_provided += ",link_down=1"
    if mtu != None:
        config_provided += ",mtu=" + str(mtu)
    if queues != None:
        config_provided += ",queues=" + str(queues)
    if rate != None:
        config_provided += ",rate=" + str(rate)
    if tag != None:
        config_provided += ",tag=" + str(tag)
    if trunks != None:
        trunks_str = ""
        for i in range(len(trunks)):
            if i > 0:
                trunks_str += ";"
            trunks_str += str(trunks[i])
        config_provided += ",trunks=" + trunks_str

    # Handle present state
    if state == "present":
        if ctx.check_mode:
            return {"changed": True, "msg": "would update nic " + interface + " on VM " + str(vmid)}
        
        # Prepare config for API call
        config_param = interface + "=" + config_provided
        
        # Build auth header
        auth_header = ""
        if api_token_id != None:
            auth_header = "PVEAPIToken=" + api_user + "!" + api_token_id + "=" + api_token_secret
        else:
            auth_header = api_user + ":" + api_password
        
        # Perform actual update via API
        res = ctx.run([
            "curl", "-s", "-k", "-X", "PUT",
            "-H", "Content-Type: application/x-www-form-urlencoded",
            "-H", "Authorization: " + auth_header,
            "https://" + api_host + ":8006/api2/json/nodes/*/qemu/" + str(vmid) + "/config",
            "--data", config_param,
        ])
        if res.rc != 0:
            fail("failed to update nic: " + res.stderr)
        
        return {"changed": True, "msg": "nic " + interface + " updated on VM " + str(vmid)}

    # Handle absent state
    elif state == "absent":
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete nic " + interface + " from VM " + str(vmid)}
        
        # Build auth header
        auth_header = ""
        if api_token_id != None:
            auth_header = "PVEAPIToken=" + api_user + "!" + api_token_id + "=" + api_token_secret
        else:
            auth_header = api_user + ":" + api_password
        
        res = ctx.run([
            "curl", "-s", "-k", "-X", "POST",
            "-H", "Content-Type: application/x-www-form-urlencoded",
            "-H", "Authorization: " + auth_header,
            "https://" + api_host + ":8006/api2/json/nodes/*/qemu/" + str(vmid) + "/config",
            "--data", "delete=" + interface,
        ])
        if res.rc != 0:
            fail("failed to delete nic: " + res.stderr)
        
        return {"changed": True, "msg": "nic " + interface + " deleted from VM " + str(vmid)}

    fail("unsupported state: " + state)
