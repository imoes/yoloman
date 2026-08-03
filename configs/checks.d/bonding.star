MODE_MAP = {
    "mode_0": "round-robin",
    "mode_1": "active-backup",
    "mode_2": "xor",
    "mode_3": "broadcast",
    "mode_4": "802.3ad",
    "mode_5": "transmit",
    "mode_6": "adaptive",
}

DEFAULT_IEEE_302_3AD_AGG_ID_MISSMATCH_STATE = 1
DEFAULT_EXPECT_ACTIVE = "ignore"
DEFAULT_EXPECTED_INTERFACES_STATE = 0
DEFAULT_EXPECTED_INTERFACES_NUMBER = 2
DEFAULT_MODE_STATE = 0


def _mode_state_for_mode(mode_str, config):
    lowered = mode_str.lower()
    keys = []
    for mode in MODE_MAP:
        keys.append(mode)
    for mode in sorted(keys):
        mode_name = MODE_MAP[mode]
        if mode_name in lowered:
            return config.get(mode, DEFAULT_MODE_STATE)
    return DEFAULT_MODE_STATE


def _parse_bonding_file(content):
    bond = {"interfaces": {}}
    current_iface = None
    for raw in content.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("Ethernet Channel"):
            continue
        if line.startswith("Bonding"):
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if key == "Bonding Mode":
            bond["mode"] = value
        elif key == "Slave Interface":
            current_iface = value
            bond["interfaces"][current_iface] = {"status": "up", "failures": 0}
        elif key == "MII Status":
            if current_iface != None:
                if value == "up":
                    bond["interfaces"][current_iface]["status"] = "up"
                else:
                    bond["interfaces"][current_iface]["status"] = "down"
            else:
                if value == "up":
                    bond["status"] = "up"
                else:
                    bond["status"] = "down"
        elif key == "Active Slave":
            if value and value != "None":
                bond["active"] = value
        elif key == "Primary Slave":
            if value and value != "None":
                bond["primary"] = value
    if bond.get("status") == None:
        bond["status"] = "up"
    has_down = False
    for iface_name in bond["interfaces"]:
        if bond["interfaces"][iface_name].get("status") == "down":
            has_down = True
            break
    if bond["status"] == "down" and not has_down:
        bond["status"] = "down"
    elif bond["status"] != "down" and has_down:
        bond["status"] = "degraded"
    return bond


def _read_all_bonds(ctx):
    section = {}
    res = ctx.run(["ls", "/proc/net/bonding"], mutates=False)
    if res.rc != 0:
        return section
    for name in res.stdout.split():
        path = "/proc/net/bonding/" + name
        if not ctx.file_exists(path):
            continue
        content = ctx.file_read(path)
        bond = _parse_bonding_file(content)
        section[name] = bond
    return section


def main(ctx, params):
    if params.get("_discover"):
        section = _read_all_bonds(ctx)
        discovery = []
        for bond_name in sorted(section.keys()):
            bond = section[bond_name]
            bond_status = bond.get("status", "")
            if bond_status in ("up", "degraded"):
                disp = {}
                primary = bond.get("primary", "None")
                active = bond.get("active", "None")
                if primary == "None" and active != "None":
                    disp = {"primary": active}
                discovery.append({
                    "item": bond_name,
                    "params": disp,
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section = _read_all_bonds(ctx)
    bond = section.get(item)
    if bond == None:
        return {
            "changed": False,
            "msg": "no such bonding interface: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = bond.get("status", "unknown")
    state_map = {"up": "OK", "degraded": "WARN"}
    main_state = state_map.get(status, "CRIT")
    summaries = []
    summaries.append("Status: %s" % status)
    if status not in ("up", "degraded"):
        return {
            "changed": False,
            "msg": "Status: %s" % status,
            "data": {"state": main_state, "metrics": {}, "details": "; ".join(summaries)},
        }

    mode = bond.get("mode", "")
    if params.get("bonding_mode_states") != None:
        config = params.get("bonding_mode_states", {})
        mstate = _mode_state_for_mode(mode, config)
        if mstate == 0:
            ms = "OK"
        elif mstate == 1:
            ms = "WARN"
        else:
            ms = "CRIT"
        suffix = " (not allowed)" if mstate != 0 else ""
        summaries.append("Mode: %s%s" % (mode, suffix))
    else:
        summaries.append("Mode: %s" % mode)

    if "IEEE 802.3ad" in mode:
        master_id = bond.get("aggregator_id")
        for eth in sorted(bond["interfaces"].keys()):
            slave = bond["interfaces"][eth]
            slave_id = slave.get("aggregator_id")
            if master_id == None:
                master_id = slave_id
            if slave_id != master_id:
                ms = params.get("ieee_302_3ad_agg_id_missatch_state", DEFAULT_IEEE_302_3AD_AGG_ID_MISSMATCH_STATE)
                if ms == 0:
                    ms_str = "OK"
                elif ms == 1:
                    ms_str = "WARN"
                else:
                    ms_str = "CRIT"
                summaries.append("Mismatching aggregator ID of %s: %s" % (eth, slave_id))

    speed = bond.get("speed")
    if speed != None:
        summaries.append("Speed: %s" % speed)

    current_primary = bond.get("primary", "None")
    primary = current_primary if current_primary != "None" else params.get("primary", "None")
    if primary != "None":
        summaries.append("Primary: %s" % primary)

    expect_active = params.get("expect_active", DEFAULT_EXPECT_ACTIVE)
    ifaces = bond["interfaces"]
    expected_active = None
    if expect_active == "primary":
        expected_active = primary
    elif expect_active == "lowest":
        if len(ifaces) > 0:
            sorted_keys = sorted(ifaces.keys())
            expected_active = sorted_keys[0]
        else:
            expected_active = None

    active_if = bond.get("active", "None")
    if expected_active == None:
        for eth in sorted(ifaces.keys()):
            slave = ifaces[eth]
            slave_status = slave.get("status", "")
            if slave_status == "up":
                st = "OK"
            else:
                st = "WARN"
            hw = slave.get("hwaddr")
            if hw != None:
                summaries.append("%s/%s %s" % (eth, hw, slave_status))
            else:
                summaries.append("%s %s" % (eth, slave_status))
    elif expected_active == active_if:
        summaries.append("Active: %s" % active_if)
    else:
        summaries.append("Active: %s (expected is %s)" % (active_if, expected_active))

    exp_if = params.get("expected_interfaces")
    if exp_if != None:
        actual_number = len(ifaces)
        expected_number = exp_if.get("expected_number", DEFAULT_EXPECTED_INTERFACES_NUMBER)
        exp_state = exp_if.get("state", DEFAULT_EXPECTED_INTERFACES_STATE)
        if actual_number < expected_number:
            if exp_state == 0:
                est = "OK"
            elif exp_state == 1:
                est = "WARN"
            else:
                est = "CRIT"
            summaries.append("Unexpected number of interfaces (expected: %s, got: %s)" % (expected_number, actual_number))

    overall = main_state
    if status == "degraded" and overall != "CRIT":
        overall = "WARN"
    for s in summaries:
        if "Mismatching" in s or "Unexpected number" in s:
            if overall != "CRIT":
                overall = "WARN"

    return {
        "changed": False,
        "msg": "; ".join(summaries),
        "data": {"state": overall, "metrics": {}, "details": "; ".join(summaries)},
    }