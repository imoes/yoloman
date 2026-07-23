def main(ctx, params):
    # === Constants ===
    DEFAULT_LEVELS_MAX = (5.0, 10.0)
    DEFAULT_LEVELS_AVE = (5.0, 10.0)

    def _parse_section():
        # Read agent section data from /proc or via direct command.
        # The Checkmk plugin reads the agent section 'corosync_latency',
        # which comes from the corosync agent plugin that executes 'corosync-quorumtool -l'.
        # We replicate that command: corosync-quorumtool -l
        res = ctx.run(["corosync-quorumtool", "-l"], mutates=False)
        if res.rc != 0:
            # Quorumtool not available or error — return empty section
            return {}
        # Parse the output: lines like:
        #   ring_0 192.168.1.1 latency_min=0.010 latency_max=0.025 latency_ave=0.015 connected=1 samples=100
        # Note: Checkmk plugin uses dot-separated metric keys, but raw output is space-separated key=value.
        lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        data = {}
        for line in lines:
            parts = line.split()
            if len(parts) < 3:
                continue
            # First part is interface name (e.g., "ring_0"), second is IP
            link_name = parts[0]
            hostname = parts[1]
            metrics = {}
            for p in parts[2:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    metrics[k] = float(v)
            # Map keys: connected, latency_min, latency_max, latency_ave, samples
            if "connected" in metrics and "latency_max" in metrics and "latency_ave" in metrics and "latency_min" in metrics:
                key = hostname + "." + link_name
                data.setdefault(hostname, {}).setdefault(link_name, {}).update({
                    "connected": int(metrics["connected"]),
                    "latency_ave": metrics["latency_ave"],
                    "latency_max": metrics["latency_max"],
                    "latency_min": metrics["latency_min"],
                    "latency_samples": metrics["samples"] if "samples" in metrics else 0.0,
                })
        # Build section
        section = {}
        for host, links in data.items():
            for link_name, link_data in links.items():
                item = host + "." + link_name
                section[item] = {
                    "hostname": host,
                    "name": link_name,
                    "connected": bool(link_data["connected"]),
                    "latency_ave": link_data["latency_ave"],
                    "latency_max": link_data["latency_max"],
                    "latency_min": link_data["latency_min"],
                    "latency_samples": link_data["latency_samples"],
                }
        return section

    def _check_levels(value, levels):
        # Checkmk's check_levels logic for upper levels:
        # - levels is a tuple: ("fixed", (warn, crit))
        if levels[0] != "fixed":
            return "OK", 0.0, 0.0
        warn, crit = levels[1]
        if value >= crit:
            return "CRIT", warn, crit
        elif value >= warn:
            return "WARN", warn, crit
        else:
            return "OK", warn, crit

    def _format_time(val):
        # Checkmk uses render.timespan
        # val in seconds; format as human readable
        if val < 1:
            return "%f ms" % (val * 1000)
        return "%f s" % val

    # === Discovery mode ===
    if params.get("_discover"):
        section = _parse_section()
        items = []
        for item in section:
            items.append({
                "item": item,
                "params": {"latency_max": ("fixed", DEFAULT_LEVELS_MAX), "latency_ave": ("fixed", DEFAULT_LEVELS_AVE)},
                "metrics": ["latency_max", "latency_ave"]
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items}
        }

    # === Check mode ===
    item = params.get("item", "")
    if item == None:
        item = ""

    section = _parse_section()
    link = section.get(item)
    if link == None:
        return {
            "changed": False,
            "msg": "item not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if not link["connected"]:
        return {
            "changed": False,
            "msg": "Link is not connected or down",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    latency_max_sec = link["latency_max"] / 1000000.0
    latency_ave_sec = link["latency_ave"] / 1000000.0

    # Extract levels from params with defaults
    latency_max_levels = params.get("latency_max", ("fixed", DEFAULT_LEVELS_MAX))
    latency_ave_levels = params.get("latency_ave", ("fixed", DEFAULT_LEVELS_AVE))

    state_max, _, _ = _check_levels(latency_max_sec, latency_max_levels)
    state_ave, _, _ = _check_levels(latency_ave_sec, latency_ave_levels)

    # Final state: CRIT > WARN > OK
    state = "OK"
    if state_max == "CRIT" or state_ave == "CRIT":
        state = "CRIT"
    elif state_max == "WARN" or state_ave == "WARN":
        state = "WARN"

    msg_parts = []
    msg_parts.append("Latency Max: " + _format_time(latency_max_sec))
    msg_parts.append("Latency Ave: " + _format_time(latency_ave_sec))
    msg = ", ".join(msg_parts)

    metrics = {
        "latency_max": latency_max_sec,
        "latency_ave": latency_ave_sec,
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }