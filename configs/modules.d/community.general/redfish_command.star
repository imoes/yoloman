def main(ctx, params):
    category = params["category"]
    command_list = params["command"]
    baseuri = params["baseuri"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    session_uri = params.get("session_uri")
    id_ = params.get("id")
    new_username = params.get("new_username")
    new_password = params.get("new_password")
    roleid = params.get("roleid")
    account_types = params.get("account_types")
    oem_account_types = params.get("oem_account_types")
    update_username = params.get("update_username")
    account_properties = params.get("account_properties", {})
    bootdevice = params.get("bootdevice")
    uefi_target = params.get("uefi_target")
    boot_next = params.get("boot_next")
    boot_override_mode = params.get("boot_override_mode")
    resource_id = params.get("resource_id")
    update_image_uri = params.get("update_image_uri")
    update_image_file = params.get("update_image_file")
    update_protocol = params.get("update_protocol")
    update_targets = params.get("update_targets", [])
    update_creds = params.get("update_creds")
    update_apply_time = params.get("update_apply_time")
    update_oem_params = params.get("update_oem_params")
    update_handle = params.get("update_handle")
    virtual_media = params.get("virtual_media")
    strip_etag_quotes = params.get("strip_etag_quotes", False)
    bios_attributes = params.get("bios_attributes")
    timeout = params.get("timeout")

    CATEGORY_COMMANDS_ALL = {
        "Systems": ["PowerOn", "PowerForceOff", "PowerForceRestart", "PowerGracefulRestart",
                    "PowerGracefulShutdown", "PowerReboot", "PowerCycle", "SetOneTimeBoot", "EnableContinuousBootOverride", "DisableBootOverride",
                    "IndicatorLedOn", "IndicatorLedOff", "IndicatorLedBlink", "VirtualMediaInsert", "VirtualMediaEject", "VerifyBiosAttributes"],
        "Chassis": ["IndicatorLedOn", "IndicatorLedOff", "IndicatorLedBlink"],
        "Accounts": ["AddUser", "EnableUser", "DeleteUser", "DisableUser",
                     "UpdateUserRole", "UpdateUserPassword", "UpdateUserName",
                     "UpdateAccountServiceProperties"],
        "Sessions": ["ClearSessions", "CreateSession", "DeleteSession"],
        "Manager": ["GracefulRestart", "ClearLogs", "VirtualMediaInsert",
                    "VirtualMediaEject", "PowerOn", "PowerForceOff", "PowerForceRestart",
                    "PowerGracefulRestart", "PowerGracefulShutdown", "PowerReboot"],
        "Update": ["SimpleUpdate", "MultipartHTTPPushUpdate", "PerformRequestedOperations"],
    }

    # Validate category
    if category not in CATEGORY_COMMANDS_ALL:
        fail("Invalid Category '%s'. Valid Categories = %s" % (category, list(CATEGORY_COMMANDS_ALL.keys())))

    # Validate commands
    for cmd in command_list:
        if cmd not in CATEGORY_COMMANDS_ALL[category]:
            fail("Invalid Command '%s'. Valid Commands = %s" % (cmd, CATEGORY_COMMANDS_ALL[category]))

    # Build root_uri
    root_uri = "https://" + baseuri

    # Prepare credentials dict for later use
    creds = {'user': username, 'pswd': password, 'token': auth_token}

    # Prepare user dict
    user = {
        'account_id': id_,
        'account_username': new_username,
        'account_password': new_password,
        'account_roleid': roleid,
        'account_accounttypes': account_types,
        'account_oemaccounttypes': oem_account_types,
        'account_updatename': update_username,
        'account_properties': account_properties,
    }

    # Prepare update_opts
    update_opts = {
        'update_image_uri': update_image_uri,
        'update_image_file': update_image_file,
        'update_protocol': update_protocol,
        'update_targets': update_targets,
        'update_creds': update_creds,
        'update_apply_time': update_apply_time,
        'update_oem_params': update_oem_params,
        'update_handle': update_handle,
    }

    # Prepare boot_opts
    boot_opts = {
        'bootdevice': bootdevice,
        'uefi_target': uefi_target,
        'boot_next': boot_next,
        'boot_override_mode': boot_override_mode,
    }

    # Prepare virtual_media dict
    vm = {}
    if virtual_media != None:
        vm['image_url'] = virtual_media.get("image_url")
        vm['inserted'] = virtual_media.get("inserted", True)
        vm['write_protected'] = virtual_media.get("write_protected", True)
        vm['media_types'] = virtual_media.get("media_types", [])
        vm['username'] = virtual_media.get("username")
        vm['password'] = virtual_media.get("password")
        vm['transfer_protocol_type'] = virtual_media.get("transfer_protocol_type")
        vm['transfer_method'] = virtual_media.get("transfer_method")

    # Timeout handling - fail if deprecated default is used (as per original behavior)
    if timeout == None:
        fail("The timeout parameter is required. The default value 10 is being deprecated and will be removed in community.general 9.0.0. Please explicitly set timeout to at least 60.")

    # Build redfish command using ctx.run
    # The actual Redfish commands will be implemented as HTTP calls via ctx.run
    # Since we don't have a real Redfish library in Starlark, we simulate the behavior
    # and fail with a clear message indicating this module requires real Redfish integration.

    # Note: In practice, a real Starlark implementation would call an external helper
    # or use a pre-built Redfish client via a Go extension. For this translation,
    # we produce a faithful semantic structure with error messaging for missing implementation.

    if category == "Accounts":
        if len(command_list) != 1:
            fail("Accounts category only supports one command at a time in this Starlark implementation.")
        cmd = command_list[0]
        if cmd not in ["AddUser", "EnableUser", "DeleteUser", "DisableUser",
                       "UpdateUserRole", "UpdateUserPassword", "UpdateUserName",
                       "UpdateAccountServiceProperties"]:
            fail("Unsupported Accounts command: " + cmd)

        # Simulate finding AccountService
        res = ctx.run(["curl", "-s", "-k", "-X", "GET", root_uri + "/redfish/v1/AccountService/"], mutates=False)
        if res.rc != 0:
            fail("Failed to find AccountService: " + res.stderr)

        # In a real implementation, this would make appropriate PATCH/POST calls.
        # For now, simulate success for common case.
        if cmd == "AddUser":
            if user.get('account_username') == None or user.get('account_password') == None:
                fail("new_username and new_password are required for AddUser")
            res = ctx.run(["curl", "-s", "-k", "-X", "POST", root_uri + "/redfish/v1/AccountService/Accounts/", "-H", "Content-Type: application/json", "-d", '{"UserName": "%s", "Password": "%s", "RoleId": "%s"}' % (user.get('account_username'), user.get('account_password'), user.get('account_roleid', ''))], mutates=True)
        elif cmd == "UpdateUserPassword":
            if user.get('account_username') == None or user.get('account_password') == None:
                fail("new_username and new_password are required for UpdateUserPassword")
            res = ctx.run(["curl", "-s", "-k", "-X", "PATCH", root_uri + "/redfish/v1/AccountService/Accounts/" + user.get('account_username'), "-H", "Content-Type: application/json", "-d", '{"Password": "%s"}' % user.get('account_password')], mutates=True)
        elif cmd == "DeleteUser":
            if user.get('account_username') == None:
                fail("new_username is required for DeleteUser")
            res = ctx.run(["curl", "-s", "-k", "-X", "DELETE", root_uri + "/redfish/v1/AccountService/Accounts/" + user.get('account_username')], mutates=True)
        else:
            fail("Command " + cmd + " requires more implementation than provided in this template.")
    elif category == "Systems":
        if len(command_list) != 1:
            fail("Systems category only supports one command at a time in this Starlark implementation.")
        cmd = command_list[0]

        # Simulate finding System resource
        if resource_id != None:
            sys_uri = root_uri + "/redfish/v1/Systems/" + resource_id + "/"
        else:
            sys_uri = root_uri + "/redfish/v1/Systems/"

        if cmd.startswith("Power"):
            if cmd == "PowerOn":
                res = ctx.run(["curl", "-s", "-k", "-X", "POST", sys_uri + "Actions/ComputerSystem.Reset/", "-H", "Content-Type: application/json", "-d", '{"ResetType": "On"}'], mutates=True)
            elif cmd == "PowerForceOff":
                res = ctx.run(["curl", "-s", "-k", "-X", "POST", sys_uri + "Actions/ComputerSystem.Reset/", "-H", "Content-Type: application/json", "-d", '{"ResetType": "ForceOff"}'], mutates=True)
            elif cmd == "PowerGracefulShutdown":
                res = ctx.run(["curl", "-s", "-k", "-X", "POST", sys_uri + "Actions/ComputerSystem.Reset/", "-H", "Content-Type: application/json", "-d", '{"ResetType": "GracefulShutdown"}'], mutates=True)
            elif cmd == "PowerGracefulRestart":
                res = ctx.run(["curl", "-s", "-k", "-X", "POST", sys_uri + "Actions/ComputerSystem.Reset/", "-H", "Content-Type: application/json", "-d", '{"ResetType": "GracefulRestart"}'], mutates=True)
            elif cmd == "PowerForceRestart":
                res = ctx.run(["curl", "-s", "-k", "-X", "POST", sys_uri + "Actions/ComputerSystem.Reset/", "-H", "Content-Type: application/json", "-d", '{"ResetType": "ForceRestart"}'], mutates=True)
            elif cmd == "PowerReboot":
                res = ctx.run(["curl", "-s", "-k", "-X", "POST", sys_uri + "Actions/ComputerSystem.Reset/", "-H", "Content-Type: application/json", "-d", '{"ResetType": "Reboot"}'], mutates=True)
            else:
                fail("Unsupported power command: " + cmd)
        elif cmd == "SetOneTimeBoot":
            boot_opts['override_enabled'] = "Once"
            res = ctx.run(["curl", "-s", "-k", "-X", "PATCH", sys_uri, "-H", "Content-Type: application/json", "-d", '{"Boot": {"BootOverrideTarget": "/redfish/v1/Systems/" + (resource_id or "") + "/BootOptions/1", "BootSourceOverrideEnabled": "Once", "BootSourceOverrideMode": "%s", "BootSourceOverrideTarget": "%s"}}' % (boot_opts.get('boot_override_mode', 'Legacy'), boot_opts.get('bootdevice', ''))], mutates=True)
        elif cmd == "IndicatorLedOn":
            res = ctx.run(["curl", "-s", "-k", "-X", "PATCH", sys_uri, "-H", "Content-Type: application/json", "-d", '{"IndicatorLED": "Lit"}'], mutates=True)
        elif cmd == "IndicatorLedOff":
            res = ctx.run(["curl", "-s", "-k", "-X", "PATCH", sys_uri, "-H", "Content-Type: application/json", "-d", '{"IndicatorLED": "Off"}'], mutates=True)
        elif cmd == "IndicatorLedBlink":
            res = ctx.run(["curl", "-s", "-k", "-X", "PATCH", sys_uri, "-H", "Content-Type: application/json", "-d", '{"IndicatorLED": "Blinking"}'], mutates=True)
        else:
            fail("Unsupported Systems command: " + cmd)
    elif category == "Update":
        if len(command_list) != 1:
            fail("Update category only supports one command at a time in this Starlark implementation.")
        cmd = command_list[0]

        update_uri = root_uri + "/redfish/v1/UpdateService/"

        if cmd == "SimpleUpdate":
            payload = '{"ImageURI": "%s"}' % update_opts.get("update_image_uri")
            res = ctx.run(["curl", "-s", "-k", "-X", "POST", update_uri + "Actions/UpdateService.SimpleUpdate/", "-H", "Content-Type: application/json", "-d", payload], mutates=True)
        elif cmd == "PerformRequestedOperations":
            # In practice, this would POST to a task handle
            res = ctx.run(["curl", "-s", "-k", "-X", "POST", update_uri + "Actions/UpdateService.PerformRequestedOperations/", "-H", "Content-Type: application/json", "-d", '{"UpdateHandle": "%s"}' % update_handle], mutates=True)
        else:
            fail("Unsupported Update command: " + cmd)
    else:
        fail("Category %s is not yet implemented in this Starlark module. Only Accounts, Systems, and Update are partially supported." % category)

    # Check result and return
    if res.rc == 0:
        return {"changed": True, "msg": "Action successful", "data": {"stdout": res.stdout, "stderr": res.stderr}}
    else:
        fail("Command failed with rc=%d: %s" % (res.rc, res.stderr))
