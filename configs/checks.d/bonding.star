# Bonding check module for yolo-man agent
# Read-only: gathers bond state from /proc/net/bonding and reports status, mode, interfaces.

# Mode map (same as Checkmk)
MODE_MAP = {
    "mode_0": "round-robin",
    "mode_1": "active-backup",
    "mode_2": "xor",
    "mode_3": "broadcast",
    "mode_4": "802.3ad",
    "mode_5": "transmit",
    "mode_6": "adaptive",
}

def _parse_bond_proc(content):
    """Parse /proc/net/bonding content into a section dict of bonds."""
    bonds = {}
    current_bond = None
    lines = content.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line == "" or line.startswith("Ethernet Channel Bonding Driver"):
            i += 1
            continue

        # Slave Interface: eth0
        if line.startswith("Slave Interface:"):
            iface = line.split(":", 1)[1].strip()
            if current_bond == None:
                # Use "bond0" as fallback
                current_bond = "bond0"
            if current_bond not in bonds:
                bonds[current_bond] = {
                    "interfaces": {},
                    "status": "up",
                    "mode": "unknown",
                }
            bonds[current_bond]["interfaces"][iface] = {
                "status": "up",
                "hwaddr": "",
                "failures": 0,
            }
            i += 1
            continue

        # MII Status for slave: "MII Status: up"
        if line.startswith("MII Status:"):
            if current_bond != None and current_bond in bonds:
                iface_list = list(bonds[current_bond]["interfaces"].keys())
                if len(iface_list) > 0:
                    iface = iface_list[-1]
                    status = line.split(":", 1)[1].strip().lower()
                    bonds[current_bond]["interfaces"][iface]["status"] = status
                    if status == "down":
                        bonds[current_bond]["status"] = "degraded"
            i += 1
            continue

        # Link Speed: 1000 Mbps
        if line.startswith("Link Speed:"):
            if current_bond != None and current_bond in bonds:
                iface_list = list(bonds[current_bond]["interfaces"].keys())
                if len(iface_list) > 0:
                    iface = iface_list[-1]
                    speed_str = line.split(":", 1)[1].strip()
                    bonds[current_bond]["speed"] = speed_str
            i += 1
            continue

        # Permanent HW addr: ...
        if line.startswith("Permanent HW addr:"):
            if current_bond != None and current_bond in bonds:
                iface_list = list(bonds[current_bond]["interfaces"].keys())
                if len(iface_list) > 0:
                    iface = iface_list[-1]
                    hwaddr = line.split(":", 1)[1].strip()
                    bonds[current_bond]["interfaces"][iface]["hwaddr"] = hwaddr
            i += 1
            continue

        # Bonding Mode: ...
        if line.startswith("Bonding Mode:"):
            if current_bond != None and current_bond in bonds:
                mode = line.split(":", 1)[1].strip()
                bonds[current_bond]["mode"] = mode
            i += 1
            continue

        # Primary Slave: eth0
        if line.startswith("Primary Slave:"):
            primary = line.split(":", 1)[1].strip()
            if primary == "None":
                primary = "None"
            else:
                primary = primary.split("(", 1)[0].strip()
            if current_bond != None and current_bond in bonds:
                bonds[current_bond]["primary"] = primary
            i += 1
            continue

        # Currently Active Slave: eth0
        if line.startswith("Currently Active Slave:"):
            active = line.split(":", 1)[1].strip()
            if active == "None":
                active = "None"
            else:
                active = active.split("(", 1)[0].strip()
            if current_bond != None and current_bond in bonds:
                bonds[current_bond]["active"] = active
            i += 1
            continue

        i += 1

    # Ensure all bonds have status
    for bname, bdata in bonds.items():
        if bdata.get("status") == None:
            all_up = True
            has_down = False
            for iface, idata in bdata["interfaces"].items():
                if idata["status"] != "up":
                    all_up = False
                    has_down = True
            bdata["status"] = "up" if all_up else ("degraded" if has_down else "up")

    return bonds


def _check_bonding_mode(current_mode, params):
    """Return (state, summary) for mode check."""
    config = params.get("bonding_mode_states", {})
    default_config = {
        "mode_0": 0, "mode_1": 0, "mode_2": 0,
        "mode_3": 0, "mode_4": 0, "mode_5": 0,
        "mode_6": 0,
    }
    for key, val in config.items():
        default_config[key] = val
    config = default_config

    state = 0
    summary = "Mode: %s" % current_mode
    for mode_key, mode_str in MODE_MAP.items():
        if mode_str in current_mode.lower():
            summary = "Mode: %s" % mode_str
            state = config.get(mode_key, 0)
            if state != 0:
                summary = summary + " (not allowed)"
            break

    return ("OK" if state == 0 else ("WARN" if state == 1 else "CRIT"), summary)


def main(ctx, params):
    if params.get("_discover"):
        proc_path = "/proc/net/bonding"
        if not ctx.file_exists(proc_path):
            return {"changed": False, "msg": "discovered 0 bonds (no /proc/net/bonding)",
                    "data": {"discovery": []}}

        files_res = ctx.run(["ls", proc_path], mutates=False)
        files = []
        for f in files_res.stdout.splitlines():
            if f.startswith("bond"):
                files.append(f)

        discovery = []
        for filename in files:
            bond_path = proc_path + "/" + filename
            if ctx.file_exists(bond_path):
                content = ctx.file_read(bond_path)
                section = _parse_bond_proc(content)
                if filename in section:
                    bond = section[filename]
                    if bond.get("status") in ["up", "degraded"]:
                        primary = bond.get("primary", "None")
                        if primary == "None" and bond.get("active") != "None":
                            primary = bond.get("active")
                        params_dict = {}
                        if primary != "None":
                            params_dict["primary"] = primary
                        discovery.append({
                            "item": filename,
                            "params": params_dict,
                            "metrics": [],
                        })
        return {"changed": False, "msg": "discovered %d bonds" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    bond_path = "/proc/net/bonding/" + item
    if not ctx.file_exists(bond_path):
        return {"changed": False, "msg": "bond %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(bond_path)
    section = _parse_bond_proc(content)
    if item not in section:
        return {"changed": False, "msg": "bond %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    bond = section[item]
    status = bond.get("status", "up")
    state_map = {"up": "OK", "degraded": "WARN"}
    state = state_map.get(status, "CRIT")
    lines = ["Status: %s" % status]

    mode = bond.get("mode", "unknown")
    mode_state, mode_summary = _check_bonding_mode(mode, params)
    lines.append(mode_summary)

    # IEEE 802.3ad aggregator ID mismatch
    if "IEEE 802.3ad" in mode:
        master_id = None
        for eth, slave in bond["interfaces"].items():
            slave_id = slave.get("aggregator_id")
            if slave_id != None:
                if master_id == None:
                    master_id = slave_id
                if slave_id != master_id:
                    lines.append("Mismatching aggregator ID of %s: %s" % (eth, slave_id))
                    state = "WARN"

    # Speed
    if "speed" in bond:
        lines.append("Speed: %s" % bond["speed"])

    # Primary
    current_primary = bond.get("primary", "None")
    primary = current_primary if current_primary != "None" else params.get("primary", "None")
    if primary != "None":
        lines.append("Primary: %s" % primary)

    # Interfaces status
    expected_active = {
        "primary": primary,
        "lowest": min(list(bond["interfaces"].keys())) if bond["interfaces"] else "",
        "ignore": None,
    }.get(params.get("expect_active", "ignore"))

    active_if = bond.get("active", "None")
    if expected_active == None:
        for eth, slave in bond["interfaces"].items():
            slave_state = "OK" if slave["status"] == "up" else "WARN"
            if slave.get("hwaddr"):
                lines.append("%s/%s %s" % (eth, slave["hwaddr"], slave["status"]))
            else:
                lines.append("%s %s" % (eth, slave["status"]))
            if slave_state == "WARN":
                state = "WARN"
    elif expected_active == active_if:
        lines.append("Active: %s" % active_if)
    else:
        lines.append("Active: %s (expected is %s)" % (active_if, expected_active))
        state = "WARN"

    # Expected interfaces number
    expected_if = params.get("expected_interfaces")
    if expected_if != None:
        actual = len(bond["interfaces"])
        expected_num = expected_if.get("expected_number", 0)
        if actual < expected_num:
            lines.append("Unexpected number of interfaces (expected: %d, got: %d)" % (expected_num, actual))
            state = "WARN"

    msg = ", ".join(lines)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}