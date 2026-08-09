def main(ctx, params):
    name = params["name"]
    port = params.get("port", 623)
    user = params["user"]
    password = params["password"]
    state = params.get("state", "present")
    bootdev = params["bootdev"]
    persistent = params.get("persistent", False)
    uefiboot = params.get("uefiboot", False)
    key_hex = params.get("key")

    # Validate bootdev choices
    valid_bootdevs = ["network", "floppy", "hd", "safe", "optical", "setup", "default"]
    if bootdev not in valid_bootdevs:
        fail("invalid bootdev '" + bootdev + "', must be one of: " + ", ".join(valid_bootdevs))

    # Validate state
    if state not in ["present", "absent"]:
        fail("invalid state '" + state + "', must be 'present' or 'absent'")

    # Validate key if provided
    key = None
    if key_hex != None:
        # Validate hex string (even length, only 0-9a-fA-F chars)
        hex_chars = "0123456789abcdefABCDEF"
        for ch in key_hex:
            if ch not in hex_chars:
                fail("key must be a valid hex string (only hex digits)")
        if len(key_hex) % 2 != 0:
            fail("key must have even length")
        # Convert hex string to list of bytes
        key = []
        for i in range(0, len(key_hex), 2):
            byte_val = int(key_hex[i:i+2], 16)
            key.append(byte_val)

    # Build ipmitool command for get_bootdev
    get_cmd = _build_ipmitool_cmd(ctx, name, port, user, password, key, ["power", "bootdev", "get"])

    # Probe current state
    res = ctx.run(get_cmd, mutates=False)
    if res.rc != 0:
        fail("failed to get current boot device: " + res.stderr)

    # Parse current bootdev from ipmitool output
    current = _parse_bootdev_get_output(res.stdout)
    # Fallback uefimode if missing in current
    if "uefimode" not in current:
        current["uefimode"] = uefiboot

    # Determine if change is needed
    if state == "present":
        # Check if current matches desired (bootdev, persistent, uefimode)
        if (current.get("bootdev") == bootdev and
            current.get("persistent") == persistent and
            current.get("uefimode") == uefiboot):
            return {"changed": False, "msg": "boot device already set correctly", "data": current}
    elif state == "absent":
        # Check if current bootdev matches the requested device to remove
        if current.get("bootdev") == bootdev:
            # Will need to set to 'default' to remove
            pass  # proceed to change
        else:
            # Already absent for this device
            return {"changed": False, "msg": "boot device not set, nothing to remove", "data": current}
    else:
        fail("unsupported state: " + state)

    # Prepare request dict for set_bootdev
    if state == "absent":
        request_bootdev = "default"
        request_persistent = False
        request_uefiboot = False
    else:
        request_bootdev = bootdev
        request_persistent = persistent
        request_uefiboot = uefiboot

    # Build set command
    set_cmd = _build_ipmitool_cmd(ctx, name, port, user, password, key, [
        "power", "bootdev", request_bootdev,
        "--persistent=" + ("true" if request_persistent else "false"),
        "--uefiboot=" + ("true" if request_uefiboot else "false")
    ])

    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would set boot device to " + request_bootdev
        }

    # Execute set command
    res = ctx.run(set_cmd, mutates=True)
    if res.rc != 0:
        fail("failed to set boot device: " + res.stderr)

    # Build response
    response = {
        "bootdev": request_bootdev,
        "persistent": request_persistent,
        "uefimode": request_uefiboot
    }

    return {"changed": True, "msg": "boot device set to " + request_bootdev, "data": response}


def _build_ipmitool_cmd(ctx, name, port, user, password, key, subcmd):
    cmd = ["ipmitool", "-I", "lanplus", "-H", name, "-p", str(port), "-U", user, "-P", password] + subcmd
    if key != None:
        # Add kg parameter for encryption key
        key_str = ""
        for b in key:
            key_str = key_str + ("%02x" % b)
        cmd.insert(-len(subcmd), "-K")
        cmd.insert(-len(subcmd), key_str)
    return cmd


def _parse_bootdev_get_output(output):
    # ipmitool bootdev get output is typically like:
    # Boot Device              : Hard Drive
    # Boot Device Parameter Data:
    #   Persistent             : False
    #   UEFIBoot               : False
    # We extract bootdev, persistent, uefimode
    result = {}
    lines = output.strip().split("\n")
    bootdev_map = {
        "Network": "network",
        "Hard Drive": "hd",
        "Floppy": "floppy",
        "CD/DVD": "optical",
        "Setup": "setup",
        "Default": "default"
    }
    for line in lines:
        line = line.strip()
        if line.startswith("Boot Device              :"):
            dev = line.split(":", 1)[1].strip()
            if dev in bootdev_map:
                result["bootdev"] = bootdev_map[dev]
            else:
                result["bootdev"] = dev.lower()
        elif "Persistent" in line and ":" in line:
            val = line.split(":", 1)[1].strip().lower()
            if val == "true":
                result["persistent"] = True
            elif val == "false":
                result["persistent"] = False
        elif "UEFIBoot" in line and ":" in line:
            val = line.split(":", 1)[1].strip().lower()
            if val == "true":
                result["uefimode"] = True
            elif val == "false":
                result["uefimode"] = False
    return result
