# Translated from Checkmk checkmk.netctr_combined (cmk/plugins/network/agent_based/netctr.py)
# Read-only Starlark check module for the yolo-man agent.

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

# Persisted rate store passed via params (the agent maintains state between invocations).
DEFAULT_LEVELS = (0.01, 0.1)


def _is_integer(s):
    if type(s) != "string":
        return False
    if len(s) == 0:
        return False
    start = 0
    if s[0] == "-":
        start = 1
        if len(s) == 1:
            return False
    for ch in s[start:]:
        if ch < "0" or ch > "9":
            return False
    return True


def _to_mb_per_sec(value, this_time, last_time):
    if this_time == last_time:
        return 0.0
    diff_time = this_time - last_time
    if diff_time == 0:
        return 0.0
    bytes_per_sec = value / diff_time
    return bytes_per_sec / (1024.0 * 1024.0)


def main(ctx, params):
    linux_nic_check = params.get("linux_nic_check", "lnx_if")
    # Reproduce the legacy gating from the source check: only active for legacy lnx_if.
    if linux_nic_check == "legacy":
        return {"changed": False, "msg": "legacy mode disabled", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/net/dev"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no /proc/net/dev available", "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "discovered 0 interfaces", "data": {"discovery": []}}

        # First line is the header: "Inter-|   ...". Interface names are the first token of each subsequent line.
        out = []
        header = lines[0]
        # Find the pipe position; interface name is before it.
        for line in lines[1:]:
            stripped = line.rstrip("\n")
            if not stripped.strip():
                continue
            parts = stripped.split(":")
            if len(parts) < 2:
                continue
            name = parts[0].strip()
            # Skip loopback and sit interfaces (mirrors source discovery).
            if name == "lo" or name.startswith("sit"):
                continue
            out.append({
                "item": name,
                "params": {"levels": DEFAULT_LEVELS},
                "metrics": NETCTR_COUNTERS,
            })
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)
    warn = levels[0] if type(levels) == "tuple" and len(levels) >= 2 else params.get("warn", 0.01)
    crit = levels[1] if type(levels) == "tuple" and len(levels) >= 2 else params.get("crit", 0.1)

    # Probe the real source: /proc/net/dev for the named interface.
    res = ctx.run(["cat", "/proc/net/dev"], mutates=False)
    if res.rc != 0 or len(res.stdout) == 0:
        return {"changed": False, "msg": "no /proc/net/dev available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "NIC %s is not present" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    nicline = None
    for line in lines[1:]:
        parts = line.split(":")
        if len(parts) < 2:
            continue
        if parts[0].strip() == item:
            nicline = parts[1].split()
            break

    if nicline == None or len(nicline) < 16:
        return {"changed": False, "msg": "NIC %s is not present" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Compute per-second rates using the persisted rate store from params.
    this_time = int(params.get("_this_time", "0")) if _is_integer(params.get("_this_time", "0")) else 0
    last_time = 0
    last_values = {}
    store_json = params.get("_rate_store", "{}")
    if store_json != "{}":
        decoded = json.decode(store_json)
        if type(decoded) == "dict":
            last_time = decoded.get("time", 0)
            last_values = decoded.get("values", {})

    metrics = {}
    infotxt = ""
    problems_per_sec = 0.0
    packets_per_sec = 0.0

    for countername in NETCTR_COUNTERS:
        index = NETCTR_COUNTER_INDICES[countername]
        raw = nicline[index]
        if not _is_integer(raw):
            value = 0
        else:
            value = int(raw)
        metrics[countername] = value

        last_v = last_values.get(countername, value)
        if this_time > last_time:
            items_per_sec = (value - last_v) / (this_time - last_time)
        else:
            items_per_sec = 0.0

        if countername in ["rx_errors", "tx_errors", "tx_collisions"]:
            problems_per_sec += items_per_sec
        elif countername in ["rx_packets", "tx_packets"]:
            packets_per_sec += items_per_sec
        if countername == "rx_bytes":
            mbps = _to_mb_per_sec(value - last_v, this_time, last_time)
            infotxt += " - Receive: %f MB/sec" % mbps
        elif countername == "tx_bytes":
            mbps = _to_mb_per_sec(value - last_v, this_time, last_time)
            infotxt += " - Send: %f MB/sec" % mbps

    error_percentage = 0.0
    if packets_per_sec > 0 and problems_per_sec > 0:
        error_percentage = (problems_per_sec / packets_per_sec) * 100.0
        infotxt += ", error rate %f%%" % error_percentage

    state = "OK"
    if error_percentage >= crit:
        state = "CRIT"
    elif error_percentage >= warn:
        state = "WARN"

    infotxt = infotxt.lstrip(" ").lstrip("-").strip()

    return {
        "changed": False,
        "msg": infotxt,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }