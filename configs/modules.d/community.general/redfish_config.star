def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    bios_attributes = params.get("bios_attributes", {})
    boot_order = params.get("boot_order", [])
    network_protocols = params.get("network_protocols", {})
    resource_id = params.get("resource_id")
    nic_addr = params.get("nic_addr", "null")
    nic_config = params.get("nic_config", {})
    strip_etag_quotes = params.get("strip_etag_quotes", False)
    hostinterface_config = params.get("hostinterface_config", {})
    hostinterface_id = params.get("hostinterface_id")
    sessions_config = params.get("sessions_config", {})
    storage_subsystem_id = params.get("storage_subsystem_id", "")
    volume_ids = params.get("volume_ids", [])
    secure_boot_enable = params.get("secure_boot_enable", True)
    volume_details = params.get("volume_details", {})
    timeout = params.get("timeout")

    # Default timeout handling
    if timeout == None:
        timeout = 10
        ctx.warn("The default value 10 for parameter timeout is being deprecated and it will be replaced by 60 in community.general 9.0.0")

    # Validate category
    category_commands = {
        "Systems": ["SetBiosDefaultSettings", "SetBiosAttributes", "SetBootOrder",
                    "SetDefaultBootOrder", "EnableSecureBoot", "SetSecureBoot",
                    "DeleteVolumes", "CreateVolume"],
        "Manager": ["SetNetworkProtocols", "SetManagerNic", "SetHostInterface"],
        "Sessions": ["SetSessionService"],
    }

    if category not in category_commands:
        fail("Invalid Category '%s'. Valid Categories = %s" % (category, list(category_commands.keys())))

    # Validate commands
    for cmd in command_list:
        if cmd not in category_commands[category]:
            fail("Invalid Command '%s'. Valid Commands = %s" % (cmd, category_commands[category]))

    # Build base URI
    root_uri = "https://" + baseuri

    # Authentication header handling
    headers = {}
    if auth_token != None:
        headers["X-Auth-Token"] = auth_token
    elif username != None and password != None:
        # Auth via basic auth handled by ctx.run via --user flag
        pass
    elif username == None and password == None:
        fail("Either username and password or auth_token must be provided")
    else:
        fail("Both username and password must be provided together")

    # Execute commands by category
    result = {"ret": False, "changed": False, "msg": "", "warning": None}

    if category == "Systems":
        # Systems resource discovery
        res = ctx.run(["curl", "-s", "-k", "--head", root_uri + "/redfish/v1/Systems"], ok_codes=[0, 302, 301])
        if res.rc != 0:
            fail("Failed to reach Systems resource: " + res.stderr)
        # Assume success if we got a 2xx or redirect — no full resource check
        for cmd in command_list:
            if cmd == "SetBiosDefaultSettings":
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "POST",
                    root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1") + "/Bios/Actions/BIOS.ResetBios",
                    "-H", "Content-Type: application/json", "-d", "{}"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token]), mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would reset BIOS settings"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "BIOS settings reset"}
                else:
                    fail("Failed to reset BIOS settings: " + res.stderr)
            elif cmd == "SetBiosAttributes":
                payload = {"Attributes": bios_attributes}
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "PATCH",
                    root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1") + "/Bios",
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would update BIOS attributes"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "BIOS attributes updated"}
                else:
                    fail("Failed to update BIOS attributes: " + res.stderr)
            elif cmd == "SetBootOrder":
                payload = {"BootOrder": boot_order}
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "PATCH",
                    root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1"),
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would set boot order"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "Boot order updated"}
                else:
                    fail("Failed to set boot order: " + res.stderr)
            elif cmd == "SetDefaultBootOrder":
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "POST",
                    root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1") + "/Actions/ComputerSystem.ResetBootOrder",
                    "-H", "Content-Type: application/json", "-d", "{}"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token]), mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would reset default boot order"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "Default boot order reset"}
                else:
                    fail("Failed to reset default boot order: " + res.stderr)
            elif cmd == "EnableSecureBoot":
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "POST",
                    root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1") + "/SecureBoot/Actions/SecureBoot.EnableSecureBoot",
                    "-H", "Content-Type: application/json", "-d", "{}"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token]), mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would enable SecureBoot"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "SecureBoot enabled"}
                else:
                    fail("Failed to enable SecureBoot: " + res.stderr)
            elif cmd == "SetSecureBoot":
                payload = {"SecureBootEnable": secure_boot_enable}
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "PATCH",
                    root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1") + "/SecureBoot",
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would set SecureBoot"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "SecureBoot updated"}
                else:
                    fail("Failed to update SecureBoot: " + res.stderr)
            elif cmd == "DeleteVolumes":
                # Delete each volume
                changed = False
                for vid in volume_ids:
                    res = ctx.run([
                        "curl", "-s", "-k", "-X", "DELETE",
                        root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1") + "/Storage/" + storage_subsystem_id + "/Volumes/" + vid
                    ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                    + (["-H", "If-Match: *"] if strip_etag_quotes else []), mutates=True)
                    if not res.skipped and res.rc == 0:
                        changed = True
                    elif not res.skipped:
                        fail("Failed to delete volume " + vid + ": " + res.stderr)
                result = {"ret": True, "changed": changed, "msg": "Volumes deleted"}
            elif cmd == "CreateVolume":
                payload = volume_details
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "POST",
                    root_uri + "/redfish/v1/Systems/" + (resource_id if resource_id else "1") + "/Storage/" + storage_subsystem_id + "/Volumes",
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would create volume"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "Volume created"}
                else:
                    fail("Failed to create volume: " + res.stderr)

    elif category == "Manager":
        res = ctx.run(["curl", "-s", "-k", "--head", root_uri + "/redfish/v1/Managers"], ok_codes=[0, 302, 301])
        if res.rc != 0:
            fail("Failed to reach Managers resource: " + res.stderr)
        for cmd in command_list:
            if cmd == "SetNetworkProtocols":
                payload = network_protocols
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "PATCH",
                    root_uri + "/redfish/v1/Managers/" + (resource_id if resource_id else "1") + "/NetworkProtocol",
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would update network protocols"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "Network protocols updated"}
                else:
                    fail("Failed to update network protocols: " + res.stderr)
            elif cmd == "SetManagerNic":
                payload = nic_config
                addr = nic_addr if nic_addr != "null" else ""
                nic_uri = root_uri + "/redfish/v1/Managers/" + (resource_id if resource_id else "1") + "/EthernetInterfaces/" + addr
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "PATCH",
                    nic_uri,
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would update manager NIC"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "Manager NIC updated"}
                else:
                    fail("Failed to update manager NIC: " + res.stderr)
            elif cmd == "SetHostInterface":
                hostinterface = hostinterface_id if hostinterface_id else "1"
                payload = hostinterface_config
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "PATCH",
                    root_uri + "/redfish/v1/Managers/" + (resource_id if resource_id else "1") + "/HostInterfaces/" + hostinterface,
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would update host interface"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "Host interface updated"}
                else:
                    fail("Failed to update host interface: " + res.stderr)

    elif category == "Sessions":
        res = ctx.run(["curl", "-s", "-k", "--head", root_uri + "/redfish/v1/SessionService"], ok_codes=[0, 302, 301])
        if res.rc != 0:
            fail("Failed to reach Sessions resource: " + res.stderr)
        for cmd in command_list:
            if cmd == "SetSessionService":
                payload = sessions_config
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "PATCH",
                    root_uri + "/redfish/v1/SessionService",
                    "-H", "Content-Type: application/json"
                ] + (["--user", username + ":" + password] if username else ["-H", "X-Auth-Token: " + auth_token])
                + (["-H", "If-Match: *"] if strip_etag_quotes else [])
                + ["-d", str(payload)], mutates=True)
                if res.skipped:
                    result = {"ret": True, "changed": True, "msg": "would update session service"}
                elif res.rc == 0:
                    result = {"ret": True, "changed": True, "msg": "Session service updated"}
                else:
                    fail("Failed to update session service: " + res.stderr)

    # Return result
    if result.get("ret") == True:
        if result.get("warning"):
            ctx.warn(result["warning"])
        return {"changed": result["changed"], "msg": result["msg"]}
    else:
        fail(result["msg"])
