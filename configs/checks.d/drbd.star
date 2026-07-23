# DRBD check module (read-only) - translates Checkmk cmk.plugins.drbd.agent_based.drbd
# Reads /proc/drbd data via 'cat /proc/drbd' command
# Supports discovery (per DRBD device) and per-device checks

# Mapping of connection states to numeric severity (0=OK, 1=WARN, 2=CRIT)
drbd_cs_map = {
    "StandAlone": 1,
    "Disconnecting": 1,
    "Unconnected": 2,
    "Timeout": 2,
    "BrokenPipe": 2,
    "NetworkFailure": 2,
    "ProtocolError": 2,
    "TearDown": 2,
    "WFConnection": 2,
    "WFReportParams": 1,
    "Connected": 0,
    "Established": 0,
    "StartingSyncS": 1,
    "StartingSyncT": 1,
    "WFBitMapS": 1,
    "WFBitMapT": 1,
    "WFSyncUUID": 1,
    "SyncSource": 1,
    "SyncTarget": 1,
    "PausedSyncS": 1,
    "PausedSyncT": 1,
    "VerifyS": 0,
    "VerifyT": 0,
    "Ahead": 1,
    "Behind": 1,
}

# Default disk state severity by role/disk combination
drbd_ds_map = {
    "primary_Diskless": 2,
    "secondary_Diskless": 2,
    "primary_Attaching": 2,
    "secondary_Attaching": 2,
    "primary_Failed": 2,
    "secondary_Failed": 2,
    "primary_Negotiating": 2,
    "secondary_Negotiating": 2,
    "primary_Inconsistent": 1,
    "secondary_Inconsistent": 1,
    "primary_Outdated": 2,
    "secondary_Outdated": 2,
    "primary_DUnknown": 2,
    "secondary_DUnknown": 2,
    "primary_Consistent": 2,
    "secondary_Consistent": 2,
    "primary_UpToDate": 0,
    "secondary_UpToDate": 0,
    "unknown_DUnknown": 2,
}

def _parse_count(raw):
    """Parse DRBD counter value (handles bracket notation for sub-fields)"""
    if raw.startswith("[") and raw.endswith("]"):
        inner = raw[1:-1]
        parts = inner.split(";")
        acc = 0
        for p in parts:
            if p.isdigit():
                acc += int(p)
            else:
                return 0
        return acc
    if raw.isdigit():
        return int(raw)
    return 0

def _get_role_state(roles, params):
    """Evaluate role status and return (state_int, summary)"""
    output = "Roles: %s/%s" % (roles[0], roles[1])
    current_roles = roles[0].lower() + "_" + roles[1].lower()
    state = 0
    found = False

    # Check explicit role rules
    if params.get("roles") != None:
        for rule in params.get("roles"):
            if rule[0] == current_roles:
                found = True
                state = max(state, rule[1])
                break
    else:
        found = True

    # Check inventory-based expectations
    if not found:
        inventory_roles = params.get("roles_inventory")
        if inventory_roles != None:
            if roles[0] != inventory_roles[0] or roles[1] != inventory_roles[1]:
                state = max(state, 2)
                output += " (Expected: %s/%s)" % (inventory_roles[0], inventory_roles[1])
        else:
            state = max(state, 3)
            output += " (Check requires a new service discovery)"

    return state, output

def _get_diskstate_state(roles, diskstates, params):
    """Evaluate disk state and return (state_int, summary)"""
    output = "Diskstates: %s/%s" % (diskstates[0], diskstates[1])
    state = 0

    # Skip disk state check if disabled
    if (params.get("diskstates") != None and params["diskstates"] == None) or (params.get("diskstates_inventory") != None and params["diskstates_inventory"] == None):
        return state, output

    params_diskstates_dict = {}
    for rule in params.get("diskstates", []):
        params_diskstates_dict[rule[0]] = rule[1]

    diskstates_info = []
    for i in range(2):
        ro = roles[i]
        ds = diskstates[i]
        diskstate = ro.lower() + "_" + ds
        if params_diskstates_dict.get(diskstate) != None:
            state = max(state, params_diskstates_dict[diskstate])
            diskstates_info.append(ro + "/" + ds)
        else:
            default_state = drbd_ds_map.get(diskstate, 3)
            if default_state > 0:
                diskstates_info.append(ro + "/" + ds)
            state = max(state, default_state)

    if len(diskstates_info) > 0:
        output += " (" + ", ".join(diskstates_info) + ")"

    return state, output

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/drbd"], mutates=False)
        lines = res.stdout.split("\n")
        items = []

        # Skip first two lines (version info)
        i = 2
        while i < len(lines):
            line = lines[i]
            # Look for block start: "0:", "1:", etc.
            if len(line) >= 2 and line[0].isdigit() and line[1] == ":":
                # Extract device number (e.g., "0" from "0:")
                dev_num = line.split(":")[0]
                item_name = "drbd" + dev_num

                # Parse block for this device
                block_lines = []
                while i < len(lines) and lines[i].startswith(" "):
                    block_lines.append(lines[i])
                    i += 1

                # Check if unconfigured
                parsed = {}
                for l in block_lines:
                    for part in l.split():
                        if ":" in part:
                            kv = part.split(":")
                            if len(kv) == 2:
                                key = kv[0]
                                val = kv[1]
                                if key in ["cs", "ro", "ds"]:
                                    if key in ["ro", "ds"]:
                                        parts = val.split("/")
                                        parsed[key] = parts
                                    else:
                                        parsed[key] = val

                if parsed.get("cs") == "Unconfigured":
                    i += 1
                    continue

                # Add service if we have ro and ds data
                if parsed.get("ro") != None and parsed.get("ds") != None:
                    items.append({
                        "item": item_name,
                        "params": {
                            "roles_inventory": parsed["ro"],
                            "diskstates_inventory": parsed["ds"]
                        },
                        "metrics": []
                    })
            else:
                i += 1

        return {
            "changed": False,
            "msg": "discovered %d DRBD devices" % len(items),
            "data": {"discovery": items}
        }

    # CHECK MODE
    item = params.get("item", "")
    dev_num = item[4:]  # "drbd123" -> "123"

    # Read /proc/drbd
    res = ctx.run(["cat", "/proc/drbd"], mutates=False)
    lines = res.stdout.split("\n")
    found = False
    block_lines = []
    i = 2
    while i < len(lines):
        line = lines[i]
        # Look for matching block start
        if len(line) > 0 and line[0].isdigit():
            num = line.split(":")[0]
            if num == dev_num:
                found = True
                i += 1
                # Collect block lines
                while i < len(lines) and lines[i].startswith(" "):
                    block_lines.append(lines[i])
                    i += 1
                break
        i += 1

    # Device not found
    if not found:
        return {
            "changed": False,
            "msg": "device %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse block
    parsed = {}
    for l in block_lines:
        for part in l.split():
            if ":" in part:
                kv = part.split(":")
                if len(kv) == 2:
                    key = kv[0]
                    val = kv[1]
                    if key in ["cs", "ro", "ds"]:
                        if key in ["ro", "ds"]:
                            parts = val.split("/")
                            parsed[key] = parts
                        else:
                            parsed[key] = val

    if parsed.get("cs") == None:
        return {
            "changed": False,
            "msg": "device %s: no cs value" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if parsed.get("cs") == "Unconfigured":
        return {
            "changed": False,
            "msg": 'The device "%s" is "Unconfigured"' % item,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    cs = parsed.get("cs")
    cs_state = drbd_cs_map.get(cs, 3)
    msg_parts = ["Connection State: %s" % cs]
    state = cs_state

    # Roles check
    if parsed.get("ro") != None:
        roles = parsed["ro"]
        role_state, role_msg = _get_role_state(roles, params)
        state = max(state, role_state)
        msg_parts.append(role_msg)

    # Disk states check
    if parsed.get("ds") != None:
        diskstates = parsed["ds"]
        diskstate_state, diskstate_msg = _get_diskstate_state(parsed["ro"], diskstates, params)
        state = max(state, diskstate_state)
        msg_parts.append(diskstate_msg)

    # State to string
    state_str = "OK"
    if state == 1:
        state_str = "WARN"
    elif state == 2:
        state_str = "CRIT"
    elif state >= 3:
        state_str = "UNKNOWN"

    return {
        "changed": False,
        "msg": "; ".join(msg_parts),
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }