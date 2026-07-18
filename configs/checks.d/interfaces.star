# Starlark check module for Checkmk interfaces (read-only)
# Discovered items are interface names; single-service check per interface.
# No params in discovery, params passed to check: warn, crit levels, speeds, etc.

# Module-level defaults (mirroring Checkmk's defaults)
DISCOVERY_DEFAULT_PARAMETERS = {
    "admin_states": ["up"],
    "show_instance": 0,
    "usage_upper": "inf",
}
CHECK_DEFAULT_PARAMETERS = {
    "state_admin_up": 0,
    "state_admin_down": 2,
    "state_admin_testing": 2,
    "state_link_up": 0,
    "state_link_down": 2,
    "state_link_testing": 2,
    "state_link_unknown": 2,
    "state_link_dormant": 2,
    "state_link_notPresent": 2,
    "state_link_lowerLayerDown": 2,
    "errors_upper": (10, 20),
    "traffic": None,  # no default thresholds
    "total_traffic": None,
    "average": None,
    "utilization": None,
    "utilization_upper": (80.0, 90.0),
    "utilization_lower": None,
    "speed": None,
    "speed_lower": None,
    "speed_upper": None,
    "assumed_speed": 1000000000,
    "flags": [],
}


def _parse_ifstat_line(line):
    # Parse /proc/net/dev style line: "eth0: 12345678 1234 0 0 0 0 0 0 87654321 1234 0 0 0 0 0 0"
    # Returns (name, rx_bytes, rx_packets, rx_errs, rx_drop, tx_bytes, tx_packets, tx_errs, tx_drop)
    colon = line.find(":")
    if colon == -1:
        return None
    name = line[:colon].strip()
    parts = line[colon + 1:].split()
    if len(parts) < 16:
        return None
    rx = (int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
    tx = (int(parts[8]), int(parts[9]), int(parts[10]), int(parts[11]))
    return (name, rx[0], rx[1], rx[2], rx[3], tx[0], tx[1], tx[2], tx[3])


def _get_if_names(ctx):
    # Try /proc/net/dev first, fallback to ip -o link
    if ctx.file_exists("/proc/net/dev"):
        content = ctx.file_read("/proc/net/dev")
        result = []
        for line in content.splitlines():
            if ":" in line and not line.startswith("Inter") and not line.startswith("face"):
                parsed = _parse_ifstat_line(line)
                if parsed:
                    result.append({"name": parsed[0], "rx_bytes": parsed[1], "tx_bytes": parsed[5]})
        return result
    # Fallback: use ip -o link show
    res = ctx.run(["ip", "-o", "link", "show"], mutates=False)
    if res.rc != 0:
        return []
    result = []
    for line in res.stdout.splitlines():
        # "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT..."
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        idx = parts[0].strip()
        name = parts[1].strip()
        # Filter out loopback from discovery? Checkmk doesn't by default, but we include
        result.append({"name": name})
    return result


def _list_net_ifaces(ctx):
    # List interface names under /sys/class/net (ctx has no dir-list builtin;
    # `ls` is the portable way — ctx.stat returns file attrs, not entries).
    res = ctx.run(["ls", "/sys/class/net"], mutates=False)
    if res.rc != 0:
        return []
    return [n.strip() for n in res.stdout.split() if n.strip()]

def _get_if_speeds(ctx):
    # Read /sys/class/net/*/speed (where available)
    speeds = {}
    for name in _list_net_ifaces(ctx):
        speed_path = "/sys/class/net/%s/speed" % name
        if ctx.file_exists(speed_path):
            s = ctx.file_read(speed_path).strip()
            if s.isdigit():
                speeds[name] = int(s) * 1000000  # convert MB/s to b/s
    return speeds


def _state_from_admin_and_link(admin, oper):
    # admin: "up"/"down"/"testing"/"dormant"/"notPresent"/"lowerLayerDown"/"unknown"
    # oper: "up"/"down"/"testing"/"dormant"/"notPresent"/"lowerLayerDown"/"unknown"
    # We'll approximate by mapping strings to Checkmk states
    states = {
        "up": 0,
        "down": 2,
        "testing": 2,
        "dormant": 2,
        "notPresent": 2,
        "lowerLayerDown": 2,
        "unknown": 2,
    }
    # Simplified: use oper state as primary, admin as secondary
    if oper == "unknown" and admin == "up":
        return 0
    return states.get(oper, 2)


def _format_size(b):
    # Convert bytes to human-readable string (Checkmk style: KB, MB, GB)
    for unit, divisor in [("B", 1), ("KB", 1024), ("MB", 1024*1024), ("GB", 1024*1024*1024), ("TB", 1024*1024*1024*1024)]:
        if abs(b) < divisor*1000 or unit == "TB":
            if divisor == 1:
                return "%d %s" % (b, unit)
            return "%.1f %s" % (b / float(divisor), unit)
    return "%.1f %s" % (b / (1024.0*1024*1024*1024), "TB")


def _format_rate(bps):
    # Convert bits per second to human-readable string
    for unit, divisor in [("bit/s", 1), ("kbit/s", 1000), ("Mbit/s", 1000000), ("Gbit/s", 1000000000), ("Tbit/s", 1000000000000)]:
        if abs(bps) < divisor*1000 or unit == "Tbit/s":
            if divisor == 1:
                return "%d %s" % (bps, unit)
            return "%.1f %s" % (bps / float(divisor), unit)
    return "%.1f %s" % (bps / 1000000000000.0, "Tbit/s")


def _get_current_if_data(ctx):
    # Gather current interface state and counters
    if_data = []
    # Try /proc/net/dev for counters
    dev_content = ""
    if ctx.file_exists("/proc/net/dev"):
        dev_content = ctx.file_read("/proc/net/dev")
    else:
        dev_content = ""

    # Get interface names from ip link show
    res = ctx.run(["ip", "-o", "link", "show"], mutates=False)
    if res.rc != 0:
        return if_data

    lines = res.stdout.splitlines()
    speeds = _get_if_speeds(ctx)

    for line in lines:
        # "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000"
        parts = line.split(":")
        if len(parts) < 3:
            continue
        idx = parts[0].strip()
        name = parts[1].strip()
        # Extract flags and state
        rest = ""
        if "<" in parts[2]:
            rest = parts[2].split("<")[1].split(">")[0]
        flags = rest.split(",") if rest else []
        # Determine admin state: UP flag implies admin up
        admin = "up" if "UP" in flags else "down"
        # Determine operational state
        if "LOWER_UP" in flags and "LOOPBACK" not in flags:
            oper = "up"
        elif "LOOPBACK" in flags:
            oper = "up"
        elif "DOWN" in flags or "NO_CARRIER" in flags:
            oper = "down"
        elif "DORMANT" in flags:
            oper = "dormant"
        elif "NOTPRESENT" in flags:
            oper = "notPresent"
        else:
            oper = "unknown"

        # Extract speed if possible
        speed_bps = speeds.get(name, 0)

        # Get counters from /proc/net/dev
        rx_bytes = 0
        rx_packets = 0
        rx_errs = 0
        rx_drop = 0
        tx_bytes = 0
        tx_packets = 0
        tx_errs = 0
        tx_drop = 0
        if dev_content:
            for dev_line in dev_content.splitlines():
                if ":" in dev_line:
                    dev_name = dev_line.split(":")[0].strip()
                    if dev_name == name:
                        count_parts = dev_line.split(":")[1].split()
                        if len(count_parts) >= 16:
                            rx_bytes = int(count_parts[0])
                            rx_packets = int(count_parts[1])
                            rx_errs = int(count_parts[2])
                            rx_drop = int(count_parts[3])
                            tx_bytes = int(count_parts[8])
                            tx_packets = int(count_parts[9])
                            tx_errs = int(count_parts[10])
                            tx_drop = int(count_parts[11])
                        break

        if_data.append({
            "name": name,
            "admin": admin,
            "oper": oper,
            "speed": speed_bps,
            "rx_bytes": rx_bytes,
            "rx_packets": rx_packets,
            "rx_errs": rx_errs,
            "rx_drop": rx_drop,
            "tx_bytes": tx_bytes,
            "tx_packets": tx_packets,
            "tx_errs": tx_errs,
            "tx_drop": tx_drop,
        })
    return if_data


def main(ctx, params):
    # Discovery mode: enumerate all interfaces
    if params.get("_discover"):
        if_data = _get_current_if_data(ctx)
        items = []
        for entry in if_data:
            name = entry["name"]
            # Skip loopback? Checkmk includes it by default unless excluded by ruleset
            items.append({"item": name, "params": {}, "metrics": ["rx", "tx", "rx_errors", "tx_errors", "state"]})
        return {"changed": False, "msg": "discovered %d interfaces" % len(items),
                "data": {"discovery": items}}

    # Check mode: one item
    item = params.get("item", "")
    if_data = _get_current_if_data(ctx)

    # Find matching interface
    iface = None
    for entry in if_data:
        if entry["name"] == item:
            iface = entry
            break

    if iface == None:
        return {"changed": False, "msg": "interface not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract parameters (use defaults for missing ones)
    p = params
    admin_up = p.get("state_admin_up", CHECK_DEFAULT_PARAMETERS["state_admin_up"])
    admin_down = p.get("state_admin_down", CHECK_DEFAULT_PARAMETERS["state_admin_down"])
    link_up = p.get("state_link_up", CHECK_DEFAULT_PARAMETERS["state_link_up"])
    link_down = p.get("state_link_down", CHECK_DEFAULT_PARAMETERS["state_link_down"])

    state = 0  # OK
    details_parts = []

    # Admin state check
    if iface["admin"] == "up":
        if state == 0:
            state = admin_up
        else:
            state = max(state, admin_up)
    else:
        if state == 0:
            state = admin_down
        else:
            state = max(state, admin_down)

    # Operational state check
    if iface["oper"] == "up":
        if state == 0:
            state = link_up
        else:
            state = max(state, link_up)
    else:
        if state == 0:
            state = link_down
        else:
            state = max(state, link_down)

    # Build message and metrics
    msg_parts = []
    metrics = {}

    # State text
    state_text = "up" if iface["oper"] == "up" else ("down" if iface["oper"] == "down" else iface["oper"])
    admin_text = "admin up" if iface["admin"] == "up" else ("admin down" if iface["admin"] == "down" else iface["admin"])
    msg_parts.append("%s (%s)" % (state_text, admin_text))

    # Speed
    speed_bps = iface["speed"]
    if speed_bps:
        msg_parts.append("Speed: %s" % _format_rate(speed_bps))
    else:
        assumed_speed = p.get("assumed_speed", CHECK_DEFAULT_PARAMETERS["assumed_speed"])
        if assumed_speed:
            msg_parts.append("Speed: assumed %s" % _format_rate(assumed_speed))
        else:
            msg_parts.append("Speed: unknown")

    # Traffic
    rx_bytes = iface["rx_bytes"]
    tx_bytes = iface["tx_bytes"]
    rx_str = _format_size(rx_bytes)
    tx_str = _format_size(tx_bytes)
    msg_parts.append("RX: %s, TX: %s" % (rx_str, tx_str))

    # Errors
    rx_errs = iface["rx_errs"]
    tx_errs = iface["tx_errs"]
    rx_drops = iface["rx_drop"]
    tx_drops = iface["tx_drop"]
    if rx_errs or tx_errs or rx_drops or tx_drops:
        err_parts = []
        if rx_errs:
            err_parts.append("rx_errs:%d" % rx_errs)
        if tx_errs:
            err_parts.append("tx_errs:%d" % tx_errs)
        if rx_drops:
            err_parts.append("rx_drops:%d" % rx_drops)
        if tx_drops:
            err_parts.append("tx_drops:%d" % tx_drops)
        msg_parts.append("Errors: " + ",".join(err_parts))

    # State mapping for return
    state_str = "OK" if state == 0 else ("WARN" if state == 1 else "CRIT")

    metrics["rx"] = rx_bytes
    metrics["tx"] = tx_bytes
    metrics["rx_errors"] = rx_errs
    metrics["tx_errors"] = tx_errs
    metrics["rx_dropped"] = rx_drops
    metrics["tx_dropped"] = tx_drops

    details = ""
    if iface["oper"] != "up":
        details = "Interface %s is %s (admin %s)" % (item, state_text, admin_text)

    return {"changed": False,
            "msg": "%s: %s" % (item, ", ".join(msg_parts)),
            "data": {"state": state_str, "metrics": metrics, "details": details}}
