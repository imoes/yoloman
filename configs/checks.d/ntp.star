def main(ctx, params):
    # NTP state code mapping
    NTP_STATE_CODES = {
        "x": "falsetick",
        ".": "excess",
        "-": "outlyer",
        "+": "candidat",
        "#": "selected",
        "*": "sys.peer",
        "o": "pps.peer",
        "%": "discarded",
    }

    # Helper to parse time field
    def _ntp_fmt_time(raw):
        if raw == "-":
            return 0
        if raw[-1:] == "m":
            return int(raw[:-1]) * 60
        if raw[-1:] == "h":
            return int(raw[:-1]) * 60 * 60
        if raw[-1:] == "d":
            return int(raw[:-1]) * 60 * 60 * 24
        if raw[-1:] == "y":
            return int(raw[:-1]) * 60 * 60 * 24 * 365
        return int(raw)

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["ntpq", "-p", "-n"], mutates=False)
        out = []
        lines = res.stdout.splitlines()
        for line in lines:
            # Skip header line
            if line.startswith("     remote") or line.startswith("=") or line.strip() == "":
                continue
            parts = line.split()
            if len(parts) < 11:
                continue
            statecode = parts[0]
            name = parts[1]
            reach = parts[7]
            refid = parts[2]
            # Skip unreachable peers and local clock
            if reach == "0" or refid == ".LOCL.":
                continue
            # Skip summary-only discovery (only when mode is "single")
            mode = params.get("mode", "summary")
            if mode in ("single", "both"):
                out.append({
                    "item": name,
                    "params": {"ntp_levels": [10, 200.0, 500.0]},
                    "metrics": ["offset", "jitter", "stratum"]
                })
        return {
            "changed": False,
            "msg": "discovered %d peers" % len(out),
            "data": {"discovery": out}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        # Summary mode (no item specified)
        res = ctx.run(["ntpq", "-p", "-n"], mutates=False)
        section = {}
        lines = res.stdout.splitlines()
        for line in lines:
            if line.startswith("     remote") or line.startswith("=") or line.strip() == "":
                continue
            parts = line.split()
            if len(parts) < 11:
                continue
            peer = {
                "statecode": parts[0],
                "name": parts[1],
                "refid": parts[2],
                "stratum": int(parts[3]),
                "when": _ntp_fmt_time(parts[5]),
                "reach": parts[7],
                "offset": float(parts[9]),
                "jitter": float(parts[10])
            }
            section[peer["name"]] = peer
            if None not in section and peer["statecode"] in "*o":
                section[None] = peer

        # Use system peer (None key) or fallback to first suitable peer
        peer = section.get(None)
        if peer == None:
            if section:
                return {
                    "changed": False,
                    "msg": "Found %d peers, but none is suitable" % len(section),
                    "data": {"state": "OK", "metrics": {}, "details": ""}
                }
            else:
                return {
                    "changed": False,
                    "msg": "No NTP peers found",
                    "data": {"state": "OK", "metrics": {}, "details": ""}
                }
        item = peer["name"]

    # Fetch specific peer data
    res = ctx.run(["ntpq", "-p", "-n"], mutates=False)
    peer = None
    lines = res.stdout.splitlines()
    for line in lines:
        if line.startswith("     remote") or line.startswith("=") or line.strip() == "":
            continue
        parts = line.split()
        if len(parts) >= 11 and parts[1] == item:
            peer = {
                "statecode": parts[0],
                "name": parts[1],
                "refid": parts[2],
                "stratum": int(parts[3]),
                "when": _ntp_fmt_time(parts[5]),
                "reach": parts[7],
                "offset": float(parts[9]),
                "jitter": float(parts[10])
            }
            break

    # Handle missing peer
    if peer == None:
        return {
            "changed": False,
            "msg": "No peer data found for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Check unreachable
    if peer["reach"] == "0":
        return {
            "changed": False,
            "msg": "Peer %s is unreachable" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract parameters with defaults
    levels = params.get("ntp_levels", [10, 200.0, 500.0])
    crit_stratum = levels[0]
    warn_offset = levels[1]
    crit_offset = levels[2]

    offset = peer["offset"]
    stratum = peer["stratum"]
    jitter = peer["jitter"]

    # Determine state based on thresholds
    state = "OK"
    details_parts = []

    # Offset check: upper levels warn/crit if >= threshold, lower levels warn/crit if <= -threshold
    if offset >= crit_offset or offset <= -crit_offset:
        state = "CRIT"
        details_parts.append("Offset CRIT: %f ms" % offset)
    elif offset >= warn_offset or offset <= -warn_offset:
        state = "WARN"
        details_parts.append("Offset WARN: %f ms" % offset)
    else:
        details_parts.append("Offset OK: %f ms" % offset)

    # Stratum check: upper levels only (critical at crit_stratum)
    if stratum >= crit_stratum:
        if state == "OK":
            state = "WARN"
        else:
            state = "CRIT"
        details_parts.append("Stratum CRIT: %d" % stratum)
    else:
        details_parts.append("Stratum OK: %d" % stratum)

    # Jitter: no explicit thresholds in original, but include value
    details_parts.append("Jitter: %f ms" % jitter)

    # Time since last sync
    if peer["when"] > 0:
        minutes = peer["when"] / 60.0
        if minutes < 60:
            details_parts.append("Last sync: %f min" % minutes)
        else:
            hours = minutes / 60.0
            details_parts.append("Last sync: %f h" % hours)

    # State code
    state_desc = NTP_STATE_CODES.get(peer["statecode"], "unknown")
    details_parts.append("State: %s" % state_desc)

    # Final verdict
    if state == "CRIT" and state_desc == "falsetick":
        state = "CRIT"
    elif state == "OK" and state_desc in ["sys.peer", "pps-peer", "selected", "candidat"]:
        state = "OK"
    else:
        # For other states (e.g., discarded, excess) still report OK but note state
        state = "OK"

    # Build message and return
    summary = "%s: offset=%fms, stratum=%d, jitter=%fms, state=%s" % (
        item,
        offset,
        stratum,
        jitter,
        state_desc
    )
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "offset": offset,
                "stratum": stratum,
                "jitter": jitter
            },
            "details": "; ".join(details_parts)
        }
    }