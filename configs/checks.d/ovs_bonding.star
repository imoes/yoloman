def _discovery_params(bond):
    primary = bond.get("primary", "None")
    active = bond.get("active", "None")
    if primary == "None" and active != "None":
        return {"primary": active}
    return {}

def _mode_map_get(current_mode):
    mode_map = {
        "mode_0": "round-robin",
        "mode_1": "active-backup",
        "mode_2": "xor",
        "mode_3": "broadcast",
        "mode_4": "802.3ad",
        "mode_5": "transmit",
        "mode_6": "adaptive"
    }
    for mode, mode_str in mode_map.items():
        if mode_str in current_mode.lower():
            return mode, mode_str
    return "", current_mode

def main(ctx, params):
    if params.get("_discover"):
        # Read bonding info from /proc/net/bonding
        res = ctx.run(["cat", "/proc/net/bonding"], mutates=False)
        out = []
        bonds = res.stdout.split("\n\n")
        for section in bonds:
            lines = section.splitlines()
            if len(lines) < 2:
                continue
            # First line is "Bonding Mode: ..."
            bond_name_line = lines[0]
            if not bond_name_line.startswith("Bonding Mode"):
                continue
            # Extract interface name from previous line (e.g. "Ethernet Device: eth0 (master)")
            # Instead, use "bond0" pattern: find line with colon and whitespace that looks like bond interface
            name = ""
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("bond") and ":" in stripped:
                    name = stripped.split(":")[0].strip()
                    break
            if not name:
                continue
            # Parse status: look for "MII Status: up" or similar
            status = "down"
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("MII Status"):
                    status = stripped.split(":")[1].strip().lower()
                    break
            if status not in ["up", "down", "unknown", "link fail"]:
                status = "degraded"
            if status in ["up", "degraded"]:
                bond = {"status": status}
                # Try to extract active interface
                active = ""
                for line in lines:
                    stripped = line.strip()
                    if stripped.startswith("Active Slave"):
                        active = stripped.split(":")[1].strip()
                        break
                if active:
                    bond["active"] = active
                # Try to extract primary
                primary = ""
                for line in lines:
                    stripped = line.strip()
                    if stripped.startswith("Primary Slave"):
                        primary = stripped.split(":")[1].strip()
                        break
                if primary:
                    bond["primary"] = primary
                # Try to extract mode
                mode = ""
                for line in lines:
                    stripped = line.strip()
                    if stripped.startswith("Bonding Mode"):
                        mode = stripped.split(":")[1].strip()
                        break
                if mode:
                    bond["mode"] = mode
                params_for_item = _discovery_params(bond)
                out.append({"item": name, "params": params_for_item, "metrics": []})
        return {"changed": False, "msg": "discovered %d bonding interfaces" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/net/bonding"], mutates=False)
    bonds = res.stdout.split("\n\n")
    section = {}
    for section_text in bonds:
        lines = section_text.splitlines()
        if len(lines) < 2:
            continue
        name = ""
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("bond") and ":" in stripped:
                name = stripped.split(":")[0].strip()
                break
        if name != item:
            continue
        # Parse the bond properties
        bond = {}
        status = "down"
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("MII Status"):
                status = stripped.split(":")[1].strip().lower()
                if status in ["up", "down", "unknown", "link fail"]:
                    bond["status"] = status
                    break
                else:
                    status = "degraded"
                    bond["status"] = "degraded"
                    break
        if "status" not in bond:
            bond["status"] = "down"
        if bond["status"] not in ["up", "degraded"]:
            return {"changed": False, "msg": "bond %s status %s" % (item, bond["status"]),
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        # Extract active interface
        active = ""
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("Active Slave"):
                active = stripped.split(":")[1].strip()
                break
        if active:
            bond["active"] = active
        # Extract primary interface
        primary = ""
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("Primary Slave"):
                primary = stripped.split(":")[1].strip()
                break
        if primary:
            bond["primary"] = primary
        # Extract mode
        mode = ""
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("Bonding Mode"):
                mode = stripped.split(":")[1].strip()
                break
        if mode:
            bond["mode"] = mode
        # Extract speed if present (rare in /proc/net/bonding)
        speed = ""
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("MII Speed"):
                speed = stripped.split(":")[1].strip()
                break
        if speed:
            bond["speed"] = speed
        # Extract interfaces
        interfaces = {}
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("Slave Interface:"):
                ifname = line.split(":")[1].strip()
                interface = {"status": "down"}
                i += 1
                while i < len(lines):
                    next_line = lines[i].strip()
                    if next_line.startswith("Slave Interface:") or next_line == "":
                        break
                    if next_line.startswith("Permanent HW addr"):
                        interface["hwaddr"] = next_line.split(":")[1].strip()
                    elif next_line.startswith("Link Failure Count") or next_line.startswith("Link Failure count"):
                        # Extract numeric value if possible
                        val = next_line.split(":")[1].strip()
                        if val.isdigit():
                            interface["failures"] = int(val)
                    elif next_line.startswith("Current Speed") or next_line.startswith("Speed"):
                        interface["speed"] = next_line.split(":")[1].strip()
                    i += 1
                interfaces[ifname] = interface
            else:
                i += 1
        if interfaces:
            bond["interfaces"] = interfaces
        section[item] = bond
        break
    if not section:
        return {"changed": False, "msg": "bond %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    properties = section[item]
    # Build results
    state = "OK"
    msg_parts = []
    status = properties.get("status", "unknown")
    if status == "up":
        state = "OK"
    elif status == "degraded":
        state = "WARN"
    else:
        state = "CRIT"
    msg_parts.append("Status: " + status)
    # Bonding mode check
    mode = properties.get("mode", "")
    if params.get("bonding_mode_states") != None:
        mode_config = params["bonding_mode_states"]
        mode_key, mode_str = _mode_map_get(mode)
        if mode_key:
            mode_state = mode_config.get(mode_key, 0)
            if mode_state != 0:
                msg_parts.append("Mode: %s (not allowed)" % mode_str)
            else:
                msg_parts.append("Mode: %s" % mode_str)
            if mode_state == 1:
                state = "WARN"
            elif mode_state == 2:
                state = "CRIT"
        else:
            msg_parts.append("Mode: " + mode)
    else:
        msg_parts.append("Mode: " + mode)
    # IEEE 802.3ad aggregator ID check
    if "802.3ad" in mode.lower():
        master_id = properties.get("aggregator_id")
        for eth, slave in properties.get("interfaces", {}).items():
            slave_id = slave.get("aggregator_id")
            if slave_id != None and master_id != None and slave_id != master_id:
                state = "WARN"
                msg_parts.append("Mismatching aggregator ID of %s: %s" % (eth, slave_id))
    # Speed
    if "speed" in properties:
        msg_parts.append("Speed: " + str(properties["speed"]))
    # Primary interface
    current_primary = properties.get("primary", "None")
    primary = current_primary if current_primary != "None" else params.get("primary", "None")
    if primary != "None":
        msg_parts.append("Primary: " + primary)
    # Expected active interface
    expected_active = params.get("expect_active", "ignore")
    if expected_active == "primary":
        expected_active_val = primary if primary != "None" else "None"
    elif expected_active == "lowest":
        interfaces = properties.get("interfaces", {})
        if interfaces:
            expected_active_val = sorted(interfaces.keys())[0]
        else:
            expected_active_val = "None"
    else:
        expected_active_val = None
    active_if = properties.get("active", "None")
    if expected_active_val == None:
        for eth, slave in properties.get("interfaces", {}).items():
            slave_state = "up" if slave.get("status") == "up" else "down"
            if slave_state == "up":
                if state == "OK":
                    state = "OK"
            else:
                if state == "OK":
                    state = "WARN"
            if "hwaddr" in slave:
                msg_parts.append("%s/%s %s" % (eth, slave["hwaddr"], slave_state))
            else:
                msg_parts.append("%s %s" % (eth, slave_state))
    elif expected_active_val == active_if:
        msg_parts.append("Active: " + active_if)
    else:
        state = "WARN"
        msg_parts.append("Active: %s (expected is %s)" % (active_if, expected_active_val))
    # Expected number of interfaces
    expected_interfaces = params.get("expected_interfaces")
    if expected_interfaces != None:
        actual_number = len(properties.get("interfaces", {}))
        if actual_number < expected_interfaces.get("expected_number", 0):
            state = expected_interfaces.get("state", 0)
            msg_parts.append("Unexpected number of interfaces (expected: %d, got: %d)" % (expected_interfaces["expected_number"], actual_number))
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": {}, "details": ""}
    }