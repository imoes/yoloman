def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "Summary", "params": {}, "metrics": ["in", "indisc", "inerr", "out", "outdisc", "outerr"]}]}
        }

    # Check mode for item "Summary"
    # Read cadvisor interface data from /proc/net/dev (source cadvisor uses)
    proc_content = ctx.file_read("/proc/net/dev")
    lines = proc_content.splitlines()

    # Skip header lines and find first non-loopback interface
    data = {}
    found = False
    idx = 2
    while idx < len(lines):
        if idx >= len(lines):
            break
        line = lines[idx]
        idx = idx + 1
        parts = line.split(":", 1)
        if len(parts) != 2:
            continue
        iface = parts[0].strip()
        if iface == "lo":
            continue
        stats = parts[1].split()
        if len(stats) < 16:
            continue
        # Check if all required stats are numeric
        valid = True
        for i in [0, 2, 3, 8, 10, 11]:
            if not stats[i].isdigit():
                valid = False
                break
        if not valid:
            continue
        rx_bytes = int(stats[0])
        rx_disc = int(stats[3])
        rx_err = int(stats[2])
        tx_bytes = int(stats[8])
        tx_disc = int(stats[11])
        tx_err = int(stats[10])
        # cadvisor key names
        data["if_in_total"] = float(rx_bytes)
        data["if_in_discards"] = float(rx_disc)
        data["if_in_errors"] = float(rx_err)
        data["if_out_total"] = float(tx_bytes)
        data["if_out_discards"] = float(tx_disc)
        data["if_out_errors"] = float(tx_err)
        found = True
        break

    # If no data found
    if not found:
        return {
            "changed": False,
            "msg": "no interface data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state based on errors
    state = "OK"
    msg_parts = ["Summary"]
    metrics = {}

    # Add metrics for all kept fields
    if "if_in_total" in data:
        val = data["if_in_total"]
        metrics["if_in_octets"] = val
        msg_parts.append("In: %d" % int(val))
    if "if_in_errors" in data:
        val = data["if_in_errors"]
        metrics["if_in_errors"] = val
        if val > 0:
            state = "WARN"
            msg_parts.append("In errors: %d" % int(val))
    if "if_out_total" in data:
        val = data["if_out_total"]
        metrics["if_out_octets"] = val
        msg_parts.append("Out: %d" % int(val))
    if "if_out_errors" in data:
        val = data["if_out_errors"]
        metrics["if_out_errors"] = val
        if val > 0:
            state = "WARN"
            msg_parts.append("Out errors: %d" % int(val))
    if "if_in_discards" in data:
        metrics["if_in_discards"] = data["if_in_discards"]
    if "if_out_discards" in data:
        metrics["if_out_discards"] = data["if_out_discards"]
    if "if_in_errors" in data:
        metrics["indisc"] = data["if_in_discards"]
    if "if_out_errors" in data:
        metrics["outdisc"] = data["if_out_discards"]

    msg = ", ".join(msg_parts)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }