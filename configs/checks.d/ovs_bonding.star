def main(ctx, params):
    if params.get("_discover"):
        bonds = _discover_bonds(ctx)
        out = []
        for bond_name, bond in bonds.items():
            if bond.get("status") in ("up", "degraded"):
                dp = _discovery_params(bond, params)
                out.append({"item": bond_name, "params": dp, "metrics": []})
        return {"changed": False, "msg": "discovered %d bonding interfaces" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    bonds = _discover_bonds(ctx)
    if item not in bonds:
        return {"changed": False, "msg": "no such bonding interface: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    bond = bonds[item]
    results = _check_bonding(item, params, bond)
    return results


def _discovery_params(bond, params):
    primary = bond.get("primary", "None")
    active = bond.get("active", "None")
    if primary == "None" and active != "None":
        return {"primary": active}
    return {}


def _discover_bonds(ctx):
    res = ctx.run(["ls", "/proc/net/bonding/"], mutates=False)
    if res.rc != 0:
        return {}
    bonds = {}
    for name in res.stdout.splitlines():
        name = name.strip()
        if not name:
            continue
        bond = _parse_bonding_file(ctx, name)
        if bond != None:
            bonds[name] = bond
    return bonds


def _parse_bonding_file(ctx, bond_name):
    path = "/proc/net/bonding/" + bond_name
    res = ctx.run(["cat", path], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    bond = {"interfaces": {}, "status": "up"}
    mode = ""
    lines = res.stdout.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        i += 1
        parts = line.split(":")
        key = parts[0].strip().lower().replace(" ", "_")
        val = ""
        if len(parts) > 1:
            val = parts[1].strip()
        if key == "ethernet_interface" or key == "interface":
            continue
        elif key == "mode":
            mode = val
        elif key == "redundant_power" or key == "active_slave":
            if key == "active_slave" and val != "none":
                bond["active"] = val
        elif key == "primary":
            if val == "none":
                bond["primary"] = "None"
            else:
                bond["primary"] = val
        elif key == "mii_status":
            bond["status"] = val.lower()
        elif key == "aggregator_id":
            bond["aggregator_id"] = val if val.isdigit() else None
        elif key == "speed":
            bond["speed"] = val
        elif key == "interfaces" or key == "":
            pass
        elif key.startswith("slave_") or key in ("eth2", "eth3", "eth0", "eth1"):
            if len(parts) >= 2:
                iface = parts[0].strip()
                mii = val.lower()
                if mii == "up":
                    status = "up"
                elif mii == "down" or mii == "inactive":
                    status = "down"
                else:
                    status = mii
                bond["interfaces"][iface] = {"status": status}

    # Parse interfaces section separately
    bond["interfaces"] = _parse_slaves(ctx, bond_name)
    if mode:
        bond["mode"] = mode
    return bond


def _parse_slaves(ctx, bond_name):
    path = "/sys/class/net/" + bond_name + "/slaves"
    res = ctx.run(["ls", path], mutates=False)
    ifaces = {}
    if res.rc != 0:
        return ifaces
    for line in res.stdout.splitlines():
        iface = line.strip()
        if not iface:
            continue
        # Check oper state
        op_res = ctx.run(["cat", "/sys/class/net/" + iface + "/operstate"], mutates=False)
        status = "up"
        if op_res.rc == 0:
            s = op_res.stdout.strip().lower()
            if s == "down" or s == "dormant":
                status = "down"
            elif s == "up":
                status = "up"
            else:
                status = s
        ifaces[iface] = {"status": status}
        # hwaddr
        hw_res = ctx.run(["cat", "/sys/class/net/" + iface + "/address"], mutates=False)
        if hw_res.rc == 0 and hw_res.stdout.strip():
            ifaces[iface]["hwaddr"] = hw_res.stdout.strip()
    return ifaces


def _check_bonding(item, params, bond):
    status = bond.get("status", "up")
    summary_parts = []
    state = _state_from_status(status)
    summary_parts.append("Status: " + status)
    if status not in ("up", "degraded"):
        return {"changed": False, "msg": " ; ".join(summary_parts),
                "data": {"state": _state_str(state), "metrics": {}, "details": ""}}

    mode = bond.get("mode", "")
    mode_states = params.get("bonding_mode_states")
    if mode_states != None:
        state, msummary = _check_bonding_mode(mode, mode_states)
        summary_parts.append(msummary)
    else:
        summary_parts.append("Mode: " + mode)

    if "IEEE 802.3ad" in mode or "802.3ad" in mode.lower():
        mis_state = params.get("ieee_302_3ad_agg_id_missmatch_state", 1)
        master_id = bond.get("aggregator_id")
        if master_id == None:
            master_id = None
        for eth, slave in bond["interfaces"].items():
            slave_id = slave.get("aggregator_id")
            if master_id == None:
                master_id = slave_id
            if slave_id != None and master_id != None and slave_id != master_id:
                summary_parts.append("Mismatching aggregator ID of " + eth + ": " + str(slave_id))
                state = _max_state(state, mis_state)

    speed = bond.get("speed")
    if speed != None:
        summary_parts.append("Speed: " + str(speed))

    current_primary = bond.get("primary", "None")
    if current_primary == "None":
        primary = params.get("primary", "None")
    else:
        primary = current_primary
    if primary != "None":
        summary_parts.append("Primary: " + primary)

    expect_active = params.get("expect_active", "ignore")
    active_if = bond.get("active", "None")
    expected_map = {
        "primary": primary,
        "lowest": min(bond["interfaces"].keys()) if bond["interfaces"] else "None",
        "ignore": None,
    }
    expected_active = expected_map.get(expect_active, None)

    if expected_active == None:
        for eth, slave in bond["interfaces"].items():
            sstat = slave.get("status", "down")
            s = 0 if sstat == "up" else 1
            hw = slave.get("hwaddr")
            if hw != None:
                summary_parts.append(eth + "/" + hw + " " + sstat)
            else:
                summary_parts.append(eth + " " + sstat)
            state = _max_state(state, s)
    elif expected_active == active_if:
        summary_parts.append("Active: " + active_if)
    else:
        summary_parts.append("Active: " + active_if + " (expected is " + str(expected_active) + ")")
        state = _max_state(state, 1)

    expected_ifaces = params.get("expected_interfaces")
    if expected_ifaces != None:
        actual = len(bond["interfaces"])
        exp_num = expected_ifaces.get("expected_number", 2)
        if actual < exp_num:
            summary_parts.append("Unexpected number of interfaces (expected: " + str(exp_num) + ", got: " + str(actual) + ")")
            state = _max_state(state, expected_ifaces.get("state", 0))

    return {"changed": False,
            "msg": " ; ".join(summary_parts),
            "data": {"state": _state_str(state), "metrics": {}, "details": ""}}


_mode_map = [
    ("mode_0", "round-robin"),
    ("mode_1", "active-backup"),
    ("mode_2", "xor"),
    ("mode_3", "broadcast"),
    ("mode_4", "802.3ad"),
    ("mode_5", "transmit"),
    ("mode_6", "adaptive"),
]


def _check_bonding_mode(current_mode, config):
    state = 0
    summary = "Mode: " + current_mode
    mode_lower = current_mode.lower()
    for mode_key, mode_str in _mode_map:
        if mode_str in mode_lower:
            summary = "Mode: " + mode_str
            state = config.get(mode_key, 0)
            if state != 0:
                summary += " (not allowed)"
            break
    return state, summary


def _state_from_status(status):
    if status == "up":
        return 0
    if status == "degraded":
        return 1
    return 2


_state_map = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
_str_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _state_str(n):
    return _str_map.get(n, "UNKNOWN")


def _max_state(a, b):
    if a >= b:
        return a
    return b