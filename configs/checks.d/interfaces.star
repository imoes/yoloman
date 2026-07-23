def _parse_proc_net_dev(ctx):
    """Parse /proc/net/dev into a list of dicts with interface data."""
    if not ctx.file_exists("/proc/net/dev"):
        return []
    content = ctx.file_read("/proc/net/dev")
    lines = content.splitlines()
    result = []
    for i in range(2, len(lines)):
        line = lines[i]
        if len(line.strip()) == 0:
            continue
        parts = line.strip().split()
        if len(parts) < 17:
            continue
        name = parts[0].rstrip(":")
        if name == "lo":
            continue
        rx_bytes = int(parts[1]) if parts[1].isdigit() else 0
        rx_packets = int(parts[2]) if parts[2].isdigit() else 0
        rx_errs = int(parts[3]) if parts[3].isdigit() else 0
        rx_drop = int(parts[4]) if parts[4].isdigit() else 0
        rx_fifo = int(parts[5]) if parts[5].isdigit() else 0
        rx_frame = int(parts[6]) if parts[6].isdigit() else 0
        rx_compressed = int(parts[7]) if parts[7].isdigit() else 0
        rx_multicast = int(parts[8]) if parts[8].isdigit() else 0
        tx_bytes = int(parts[9]) if parts[9].isdigit() else 0
        tx_packets = int(parts[10]) if parts[10].isdigit() else 0
        tx_errs = int(parts[11]) if parts[11].isdigit() else 0
        tx_drop = int(parts[12]) if parts[12].isdigit() else 0
        tx_fifo = int(parts[13]) if parts[13].isdigit() else 0
        tx_colls = int(parts[14]) if parts[14].isdigit() else 0
        tx_carrier = int(parts[15]) if parts[15].isdigit() else 0
        tx_compressed = int(parts[16]) if parts[16].isdigit() else 0
        data = {
            "name": name,
            "rx_bytes": rx_bytes,
            "rx_packets": rx_packets,
            "rx_errs": rx_errs,
            "rx_drop": rx_drop,
            "rx_fifo": rx_fifo,
            "rx_frame": rx_frame,
            "rx_compressed": rx_compressed,
            "rx_multicast": rx_multicast,
            "tx_bytes": tx_bytes,
            "tx_packets": tx_packets,
            "tx_errs": tx_errs,
            "tx_drop": tx_drop,
            "tx_fifo": tx_fifo,
            "tx_colls": tx_colls,
            "tx_carrier": tx_carrier,
            "tx_compressed": tx_compressed,
        }
        result.append(data)
    return result

def _parse_if_names(ctx):
    """Parse /proc/net/dev for interface names only (if_names section)."""
    if not ctx.file_exists("/proc/net/dev"):
        return {}
    content = ctx.file_read("/proc/net/dev")
    lines = content.splitlines()
    result = {}
    for i in range(2, len(lines)):
        line = lines[i]
        if len(line.strip()) == 0:
            continue
        parts = line.strip().split()
        if len(parts) >= 1:
            name = parts[0].rstrip(":")
            if name != "lo":
                result[name] = name
    return result

def main(ctx, params):
    if params.get("_discover"):
        interfaces_data = _parse_proc_net_dev(ctx)
        if_names = _parse_if_names(ctx)

        discovery_list = []
        for iface in interfaces_data:
            item = iface["name"]
            suggested_params = {
                "state": ["up"],
                "default_states": {
                    "up": 0,
                    "down": 2,
                    "testing": 3,
                    "dormant": 3,
                    "lower_layer_down": 3,
                    "not_present": 3,
                    "lower_layer_up": 0,
                },
                "infrastructure": {},
            }

            metrics = [
                "if_in_octets",
                "if_out_octets",
                "if_in_discards",
                "if_out_discards",
                "if_in_errors",
                "if_out_errors",
                "if_in_multicast",
                "if_out_multicast",
            ]

            discovery_list.append({
                "item": item,
                "params": suggested_params,
                "metrics": metrics,
            })

        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(discovery_list),
            "data": {"discovery": discovery_list},
        }

    item = params.get("item", "")
    state_params = params.get("state", ["up"])
    default_states = params.get("default_states", {
        "up": 0,
        "down": 2,
        "testing": 3,
        "dormant": 3,
        "lower_layer_down": 3,
        "not_present": 3,
        "lower_layer_up": 0,
    })

    interfaces_data = _parse_proc_net_dev(ctx)
    iface_data = None
    for iface in interfaces_data:
        if iface["name"] == item:
            iface_data = iface
            break

    if iface_data == None:
        return {
            "changed": False,
            "msg": "interface %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    oper_state = "unknown"
    if ctx.file_exists("/sys/class/net/%s/operstate" % item):
        operstate_content = ctx.file_read("/sys/class/net/%s/operstate" % item).strip()
        if operstate_content == "up":
            oper_state = "up"
        elif operstate_content == "down":
            oper_state = "down"
        else:
            oper_state = operstate_content

    state_map = {
        "up": 0,
        "down": 2,
        "testing": 3,
        "dormant": 3,
        "lower_layer_down": 3,
        "not_present": 3,
        "lower_layer_up": 0,
    }

    code = state_map.get(oper_state, 3)
    if code == 0:
        state_str = "OK"
    elif code == 2:
        state_str = "CRIT"
    else:
        state_str = "WARN"

    metrics = {
        "if_in_octets": iface_data["rx_bytes"],
        "if_out_octets": iface_data["tx_bytes"],
        "if_in_discards": iface_data["rx_drop"],
        "if_out_discards": iface_data["tx_drop"],
        "if_in_errors": iface_data["rx_errs"],
        "if_out_errors": iface_data["tx_errs"],
        "if_in_multicast": iface_data["rx_multicast"],
        "if_out_multicast": 0,
    }

    details = "Status: %s, Bytes in: %d, Bytes out: %d" % (
        oper_state,
        iface_data["rx_bytes"],
        iface_data["tx_bytes"],
    )

    return {
        "changed": False,
        "msg": "Interface %s: %s" % (item, oper_state),
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": details,
        },
    }