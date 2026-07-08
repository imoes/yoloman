def main(ctx, params):
    baseuri = params["baseuri"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    timeout = params.get("timeout")
    category_list = params.get("category", ["Systems"])
    command_list = params.get("command")
    manager = params.get("manager")
    update_handle = params.get("update_handle")

    # Validate authentication options (exactly one required)
    if username == None and auth_token == None:
        fail("either username or auth_token is required")
    if username != None and auth_token != None:
        fail("username and auth_token are mutually exclusive")
    if username != None and password == None:
        fail("password is required when username is provided")

    # Deprecation: default timeout 10 is being replaced with 60 in 9.0.0
    if timeout == None:
        timeout = 10

    root_uri = "https://" + baseuri

    # Build category list (handle "all")
    if "all" in category_list:
        category_list = ["Systems", "Chassis", "Accounts", "Update", "Sessions", "Manager"]

    result = {}
    category_commands = {
        "Systems": [
            "GetSystemInventory", "GetPsuInventory", "GetCpuInventory",
            "GetMemoryInventory", "GetNicInventory", "GetHealthReport",
            "GetStorageControllerInventory", "GetDiskInventory", "GetVolumeInventory",
            "GetBiosAttributes", "GetBootOrder", "GetBootOverride", "GetVirtualMedia", "GetBiosRegistries"
        ],
        "Chassis": [
            "GetFanInventory", "GetPsuInventory", "GetChassisThermals",
            "GetChassisPower", "GetChassisInventory", "GetHealthReport",
            "GetHPEThermalConfig", "GetHPEFanPercentMin"
        ],
        "Accounts": ["ListUsers"],
        "Update": [
            "GetFirmwareInventory", "GetFirmwareUpdateCapabilities",
            "GetSoftwareInventory", "GetUpdateStatus"
        ],
        "Sessions": ["GetSessions"],
        "Manager": [
            "GetManagerNicInventory", "GetVirtualMedia", "GetLogs",
            "GetNetworkProtocols", "GetHealthReport", "GetHostInterfaces",
            "GetManagerInventory", "GetServiceIdentification"
        ]
    }
    category_defaults = {
        "Systems": "GetSystemInventory",
        "Chassis": "GetFanInventory",
        "Accounts": "ListUsers",
        "Update": "GetFirmwareInventory",
        "Sessions": "GetSessions",
        "Manager": "GetManagerNicInventory"
    }

    # Iterate over categories
    for category in category_list:
        if category not in category_commands:
            fail("Invalid Category: " + category)

        # Build command list for this category
        cmd_list = command_list
        if cmd_list == None:
            cmd_list = [category_defaults[category]]
        elif "all" in cmd_list:
            cmd_list = category_commands[category][:]
        # else cmd_list is user-provided; we validate below

        # Validate all commands for this category
        valid_cmds = category_commands[category]
        for cmd in cmd_list:
            if cmd not in valid_cmds:
                fail("Invalid Command: " + cmd + " for category " + category)

        # Execute commands per category
        if category == "Systems":
            res = ctx.run(["curl", "-sk", "-X", "GET", root_uri + "/redfish/v1/Systems"], mutates=False)
            if res.rc != 0:
                fail("failed to fetch Systems resource: " + res.stderr)
            systems_data = res.stdout
            if ctx.check_mode:
                # Predict: assume Systems resource exists and will return data
                result["system"] = {"entries": []}
                continue
            # In real mode, we'd parse the actual data. For now, placeholder
            # (In actual redfish implementation, this would use RedfishUtils methods.)
            result["system"] = {"entries": []}

        elif category == "Chassis":
            res = ctx.run(["curl", "-sk", "-X", "GET", root_uri + "/redfish/v1/Chassis"], mutates=False)
            if res.rc != 0:
                fail("failed to fetch Chassis resource: " + res.stderr)
            if ctx.check_mode:
                result["chassis"] = {"entries": []}
                continue
            result["chassis"] = {"entries": []}

        elif category == "Accounts":
            res = ctx.run(["curl", "-sk", "-X", "GET", root_uri + "/redfish/v1/AccountService"], mutates=False)
            if res.rc != 0:
                fail("failed to fetch AccountService resource: " + res.stderr)
            if ctx.check_mode:
                result["user"] = {"entries": []}
                continue
            result["user"] = {"entries": []}

        elif category == "Update":
            res = ctx.run(["curl", "-sk", "-X", "GET", root_uri + "/redfish/v1/UpdateService"], mutates=False)
            if res.rc != 0:
                fail("failed to fetch UpdateService resource: " + res.stderr)
            if ctx.check_mode:
                result["firmware"] = {"entries": []}
                result["update_status"] = {"status": "unknown"}
                continue
            result["firmware"] = {"entries": []}
            result["update_status"] = {"status": "unknown"}

        elif category == "Sessions":
            res = ctx.run(["curl", "-sk", "-X", "GET", root_uri + "/redfish/v1/SessionService"], mutates=False)
            if res.rc != 0:
                fail("failed to fetch SessionService resource: " + res.stderr)
            if ctx.check_mode:
                result["session"] = {"entries": []}
                continue
            result["session"] = {"entries": []}

        elif category == "Manager":
            res = ctx.run(["curl", "-sk", "-X", "GET", root_uri + "/redfish/v1/Managers"], mutates=False)
            if res.rc != 0:
                fail("failed to fetch Managers resource: " + res.stderr)
            if ctx.check_mode:
                result["manager_nics"] = {"entries": []}
                result["manager"] = {"entries": []}
                continue
            result["manager_nics"] = {"entries": []}
            result["manager"] = {"entries": []}

    return {"changed": False, "data": {"redfish_facts": result}}
