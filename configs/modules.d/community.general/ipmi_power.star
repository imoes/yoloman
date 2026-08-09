def main(ctx, params):
    name = params["name"]
    port = params.get("port", 623)
    user = params["user"]
    password = params["password"]
    key = params.get("key")
    timeout = params.get("timeout", 300)
    state = params.get("state")
    machine = params.get("machine")

    # Validate required parameters
    if state == None and machine == None:
        fail("One of 'state' or 'machine' is required")

    # Validate key conversion if provided
    if key != None:
        # Validate hex format (basic check)
        if len(key) % 2 != 0:
            fail("'key' must be an even-length hex string")
        # Check hex characters
        for c in key:
            if c != "0" and c != "1" and c != "2" and c != "3" and c != "4" and c != "5" and c != "6" and c != "7" and c != "8" and c != "9" and c != "a" and c != "b" and c != "c" and c != "d" and c != "e" and c != "f" and c != "A" and c != "B" and c != "C" and c != "D" and c != "E" and c != "F":
                fail("'key' must be a valid hex string")

    INVALID_TARGET_ADDRESS = 256
    # Build command arguments
    cmd = [
        "ipmitool",
        "-I", "lanplus",
        "-H", name,
        "-p", str(port),
        "-U", user,
        "-P", password,
    ]
    if key != None:
        cmd.extend(["-K", key])

    # Determine if machine mode or single power state mode
    if machine == None:
        # Single machine mode
        # Read current power state
        probe_cmd = cmd + ["chassis", "power", "status"]
        res = ctx.run(probe_cmd)
        # ipmitool may return rc=1 on "unknown" but still produce output
        if res.rc != 0 and res.rc != 1:
            fail("Failed to probe power state: " + res.stderr)
        # Parse output: "Chassis Power is on/off"
        current_state = None
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("Chassis Power is "):
                parts = line.split()
                current_state = parts[len(parts) - 1]
                break
            i = i + 1
        if current_state == None:
            fail("Could not parse power state from ipmitool output")

        # Determine desired state
        desired_state = state
        if desired_state == None:
            fail("'state' is required when 'machine' is not specified")

        # Check if change needed
        changed = current_state != desired_state

        if not changed:
            return {"changed": False, "powerstate": current_state}

        if ctx.check_mode:
            return {"changed": True, "powerstate": desired_state}

        # Apply desired state
        action_map = {
            "on": "on",
            "off": "off",
            "shutdown": "off",
            "reset": "reset",
            "boot": "on"
        }
        action = action_map.get(desired_state, desired_state)
        # Special case: shutdown -> "soft"
        if desired_state == "shutdown":
            action_cmd = cmd + ["chassis", "power", "soft"]
        elif desired_state == "boot":
            if current_state == "on":
                action_cmd = cmd + ["chassis", "power", "reset"]
            else:
                action_cmd = cmd + ["chassis", "power", "on"]
        else:
            action_cmd = cmd + ["chassis", "power", action]

        res = ctx.run(action_cmd)
        if res.rc != 0:
            fail("Failed to set power state to " + desired_state + ": " + res.stderr)

        # Confirm change
        if desired_state in ["on", "reset"]:
            expected = "on"
        elif desired_state == "shutdown":
            expected = "off"
        else:
            expected = desired_state

        return {"changed": True, "powerstate": expected}

    else:
        # Machine mode (list of targets)
        # Check if any entry has state set
        has_state_in_machine = False
        i = 0
        while i < len(machine):
            if machine[i].get("state") != None:
                has_state_in_machine = True
                break
            i = i + 1

        if state == None and not has_state_in_machine:
            fail("Either 'state' or machine entry 'state' must be set")

        # Prepare response list
        response = []
        changed = False

        # Process each machine entry
        i = 0
        while i < len(machine):
            entry = machine[i]
            taddr = entry.get("targetAddress")
            if taddr == None:
                fail("Each machine entry must contain 'targetAddress'")
            if not isinstance(taddr, int) or taddr < 0 or taddr >= INVALID_TARGET_ADDRESS:
                fail("targetAddress must be an integer between 0 and 255")

            # Determine desired state for this target
            target_state = entry.get("state")
            if target_state == None:
                target_state = state
            if target_state == None:
                fail("Either 'state' or machine entry 'state' must be set")

            # Probe current state
            probe_cmd = cmd + ["chassis", "power", "status", "bridge", str(taddr)]
            res = ctx.run(probe_cmd)
            if res.rc != 0 and res.rc != 1:
                fail("Failed to probe power state for targetAddress " + str(taddr) + ": " + res.stderr)

            current_state = None
            lines = res.stdout.splitlines()
            j = 0
            while j < len(lines):
                line = lines[j].strip()
                if line.startswith("Chassis Power is "):
                    parts = line.split()
                    current_state = parts[len(parts) - 1]
                    break
                j = j + 1
            if current_state == None:
                fail("Could not parse power state for targetAddress " + str(taddr))

            # Check if change needed
            if current_state != target_state:
                changed = True
                if ctx.check_mode:
                    response.append({
                        "targetAddress": taddr,
                        "powerstate": target_state
                    })
                else:
                    # Apply desired state
                    action_map = {
                        "on": "on",
                        "off": "off",
                        "shutdown": "off",
                        "reset": "reset",
                        "boot": "on"
                    }
                    action = action_map.get(target_state, target_state)
                    if target_state == "shutdown":
                        action_cmd = cmd + ["chassis", "power", "soft", "bridge", str(taddr)]
                    elif target_state == "boot":
                        if current_state == "on":
                            action_cmd = cmd + ["chassis", "power", "reset", "bridge", str(taddr)]
                        else:
                            action_cmd = cmd + ["chassis", "power", "on", "bridge", str(taddr)]
                    else:
                        action_cmd = cmd + ["chassis", "power", action, "bridge", str(taddr)]

                    res = ctx.run(action_cmd)
                    if res.rc != 0:
                        fail("Failed to set power state for targetAddress " + str(taddr) + ": " + res.stderr)

                    response.append({
                        "targetAddress": taddr,
                        "powerstate": target_state
                    })
            else:
                response.append({
                    "targetAddress": taddr,
                    "powerstate": target_state
                })

            i = i + 1

        return {"changed": changed, "status": response}
