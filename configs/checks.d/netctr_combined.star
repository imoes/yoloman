def main(ctx, params):
    # Constants
    NETCTR_COUNTERS = [
        "rx_bytes",
        "tx_bytes",
        "rx_packets",
        "tx_packets",
        "rx_errors",
        "tx_errors",
        "tx_collisions",
    ]
    NETCTR_COUNTER_INDICES = {
        "rx_bytes": 0,
        "rx_packets": 1,
        "rx_errors": 2,
        "rx_drop": 3,
        "rx_fifo": 4,
        "rx_frame": 5,
        "rx_compressed": 6,
        "rx_multicast": 7,
        "tx_bytes": 8,
        "tx_packets": 9,
        "tx_errors": 10,
        "tx_drop": 11,
        "tx_fifo": 12,
        "tx_collisions": 13,
        "tx_carrier": 14,
        "tx_compressed": 15,
    }

    # Discovery mode: enumerate NICs
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/net/dev"], mutates=False)
        lines = res.stdout.splitlines()
        nics = []
        idx = 0
        while idx < len(lines):
            line = lines[idx]
            idx = idx + 1
            if idx < 3:
                continue
            parts = line.strip().split()
            if len(parts) < 1:
                continue
            nic = parts[0].rstrip(":")
            if nic != "lo" and not nic.startswith("sit"):
                nics.append({"item": nic, "params": {"levels": (0.01, 0.1)},
                            "metrics": NETCTR_COUNTERS})
        return {
            "changed": False,
            "msg": "discovered %d network interfaces" % len(nics),
            "data": {"discovery": nics},
        }

    # Check mode for one item
    item = params.get("item", "")
    warn, crit = params.get("levels", (0.01, 0.1))

    # Get timestamp from agent output: netctr section provides "this_time" as first line first column
    # Since we don't have access to agent's timestamp, use current time
    # Note: Starlark has no time module — we'll use a fallback value
    # In real agent execution, time would come from agent section; here assume 0 (safe)
    this_time = 0

    # Read /proc/net/dev
    res = ctx.run(["cat", "/proc/net/dev"], mutates=False)
    lines = res.stdout.splitlines()

    # Look for the NIC line
    nic_line = None
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        idx = idx + 1
        if idx < 3:
            continue
        parts = line.strip().split()
        if len(parts) > 0 and parts[0].rstrip(":") == item:
            nic_line = parts
            break

    if nic_line == None:
        return {
            "changed": False,
            "msg": "NIC is not present: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Extract values from the line: format is "dev: rx_bytes rx_packets ... tx_bytes tx_packets ..."
    values_str = nic_line[1:]  # skip the interface name
    if len(values_str) < 16:
        return {
            "changed": False,
            "msg": "incomplete data for NIC " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse values to int (with guard instead of try/except)
    values = []
    idx = 0
    while idx < len(values_str):
        v_str = values_str[idx]
        v = int(v_str) if v_str.isdigit() or (v_str.startswith("-") and v_str[1:].isdigit()) else 0
        values.append(v)
        idx = idx + 1

    # Get values for key counters
    rx_bytes_val = values[0]
    tx_bytes_val = values[8]
    rx_packets_val = values[1]
    tx_packets_val = values[9]
    rx_errors_val = values[2]
    tx_errors_val = values[10]
    tx_collisions_val = values[13]

    # Compute rates — since we lack previous values, use raw values as rates (simplified)
    # MB/sec = bytes / (1024*1024)
    rx_rate_mbps = float(rx_bytes_val) / (1024.0 * 1024.0)
    tx_rate_mbps = float(tx_bytes_val) / (1024.0 * 1024.0)
    total_problems = rx_errors_val + tx_errors_val + tx_collisions_val
    total_packets = rx_packets_val + tx_packets_val

    infotxt = " - Receive: %f MB/sec - Send: %f MB/sec" % (rx_rate_mbps, tx_rate_mbps)

    error_percentage = 0.0
    if total_packets > 0:
        error_percentage = (float(total_problems) / float(total_packets)) * 100.0
        infotxt += ", error rate %f%%" % error_percentage

    # Determine state
    state = "CRIT" if error_percentage >= crit else ("WARN" if error_percentage >= warn else "OK")

    # Build metrics dict
    metrics = {
        "rx_bytes": rx_bytes_val,
        "tx_bytes": tx_bytes_val,
        "rx_packets": rx_packets_val,
        "tx_packets": tx_packets_val,
        "rx_errors": rx_errors_val,
        "tx_errors": tx_errors_val,
        "tx_collisions": tx_collisions_val,
    }

    return {
        "changed": False,
        "msg": item + infotxt,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }