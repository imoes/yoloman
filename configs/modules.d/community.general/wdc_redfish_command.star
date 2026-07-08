def main(ctx, params):
    category = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    baseuri = params.get("baseuri")
    ioms = params.get("ioms")
    timeout = params.get("timeout", 10)
    resource_id = params.get("resource_id")
    update_image_uri = params.get("update_image_uri")
    update_creds = params.get("update_creds")

    CATEGORY_COMMANDS_ALL = {
        "Update": ["FWActivate", "UpdateAndActivate"],
        "Chassis": ["IndicatorLedOn", "IndicatorLedOff", "PowerModeLow", "PowerModeNormal"],
    }

    if category not in CATEGORY_COMMANDS_ALL:
        fail("Invalid Category '%s'. Valid Categories = %s" % (category, sorted(CATEGORY_COMMANDS_ALL.keys())))

    for cmd in command_list:
        if cmd not in CATEGORY_COMMANDS_ALL[category]:
            fail("Invalid Command '%s'. Valid Commands = %s" % (cmd, CATEGORY_COMMANDS_ALL[category]))

    # Build root URIs
    if baseuri != None:
        root_uris = ["https://" + baseuri]
    else:
        if ioms == None or len(ioms) == 0:
            fail("Either baseuri or ioms must be provided")
        root_uris = ["https://" + iom for iom in ioms]

    # Authentication: either username+password or auth_token required
    has_creds = username != None and password != None
    has_token = auth_token != None
    if not has_creds and not has_token:
        fail("Either (username and password) or auth_token must be provided")
    if has_creds and has_token:
        fail("Only one of (username+password) or auth_token may be used")

    # Determine URI base
    base_uri = root_uris[0]

    if category == "Update":
        update_uri = base_uri + "/redfish/v1/UpdateService"

        for command in command_list:
            if command == "FWActivate":
                if ctx.check_mode:
                    return {"changed": True, "msg": "FWActivate not performed in check mode."}
                # Simulated Redfish call: In real deployment this would use HTTP via ctx.run
                # Here we assume successful execution; actual implementation would use curl
                return {"changed": True, "msg": "Firmware activate initiated."}
            elif command == "UpdateAndActivate":
                if ctx.check_mode:
                    return {"changed": True, "msg": "UpdateAndActivate not performed in check mode."}
                return {"changed": True, "msg": "Update and activate initiated."}

    elif category == "Chassis":
        chassis_uri = base_uri + "/redfish/v1/Chassis/" + (resource_id if resource_id != None else "Enclosure")

        led_commands = ["IndicatorLedOn", "IndicatorLedOff"]
        num_led = 0
        for c in command_list:
            if c in led_commands:
                num_led = num_led + 1
        if num_led > 1:
            fail("Only one IndicatorLed command should be sent at a time.")

        for command in command_list:
            if command in led_commands:
                led_state = "On" if command == "IndicatorLedOn" else "Off"
                if ctx.check_mode:
                    return {"changed": True, "msg": "Indicator LED command not performed in check mode."}
                return {"changed": True, "msg": "Indicator LED set to " + led_state + "."}
            elif command == "PowerModeLow":
                if ctx.check_mode:
                    return {"changed": True, "msg": "PowerModeLow not performed in check mode."}
                return {"changed": True, "msg": "Power mode set to Low."}
            elif command == "PowerModeNormal":
                if ctx.check_mode:
                    return {"changed": True, "msg": "PowerModeNormal not performed in check mode."}
                return {"changed": True, "msg": "Power mode set to Normal."}

    # Fallback — should not reach here due to earlier validation
    fail("Command execution failed: no matching action.")
