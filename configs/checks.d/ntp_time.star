def main(ctx, params):
    # Read NTP peer data from 'ntpq -p' (ASCII output, same format as Checkmk agent section)
    res = ctx.run(["ntpq", "-p", "-n"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to run ntpq", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    peers = []
    for line in lines:
        # Skip header line(s) starting with * or % or + or - or space followed by remote
        if line.startswith("     remote") or line.startswith("="):
            continue
        parts = line.split()
        if len(parts) < 11:
            continue

        statecode = parts[0]
        remote = parts[1]
        refid = parts[2]
        st_str = parts[3]
        when_raw = parts[5]
        reach = parts[7]
        delay_str = parts[8]
        offset_str = parts[9]
        jitter_str = parts[10]

        # Parse stratum
        st = 0
        if st_str.isdigit():
            st = int(st_str)
        else:
            continue

        # Parse when
        when = 0
        if when_raw != "-":
            if when_raw.endswith("m"):
                if len(when_raw) > 1 and when_raw[:-1].isdigit():
                    when = int(when_raw[:-1]) * 60
            elif when_raw.endswith("h"):
                if len(when_raw) > 1 and when_raw[:-1].isdigit():
                    when = int(when_raw[:-1]) * 60 * 60
            elif when_raw.endswith("d"):
                if len(when_raw) > 1 and when_raw[:-1].isdigit():
                    when = int(when_raw[:-1]) * 60 * 60 * 24
            elif when_raw.endswith("y"):
                if len(when_raw) > 1 and when_raw[:-1].isdigit():
                    when = int(when_raw[:-1]) * 60 * 60 * 24 * 365
            elif when_raw.isdigit():
                when = int(when_raw)

        # Parse reach
        if not reach.isdigit():
            reach = "0"

        # Parse delay, offset, jitter as floats
        def parse_float(s):
            s = s.strip()
            if not s:
                return 0.0
            # Allow optional leading minus and digits/decimal point
            if s[0] == "-":
                s_rest = s[1:]
                if s_rest.replace(".", "", 1).isdigit():
                    return float(s)
                return 0.0
            if s.replace(".", "", 1).isdigit():
                return float(s)
            return 0.0

        delay = parse_float(delay_str)
        offset = parse_float(offset_str)
        jitter = parse_float(jitter_str)

        peers.append({
            "statecode": statecode,
            "name": remote,
            "refid": refid,
            "stratum": st,
            "when": when,
            "reach": reach,
            "offset": offset,
            "jitter": jitter,
        })

    # Discovery mode
    if params.get("_discover"):
        items = []
        for peer in peers:
            if peer["reach"] != "0" and peer["refid"] != ".LOCL.":
                items.append({
                    "item": peer["name"],
                    "params": {"ntp_levels": [10, 200.0, 500.0], "alert_delay": [300, 3600]},
                    "metrics": ["offset", "jitter", "stratum"]
                })
        return {"changed": False, "msg": "discovered %d peers" % len(items), "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    # Checkmk uses item "" for summary, but this check supports both single and summary.
    # Checkmk check_plugin_ntp_time uses discovery of a single summary service (item "")
    # So we treat item "" as summary mode.
    if item == "":
        # Summary mode: use system peer (None) or first suitable peer with state * or o
        peer = None
        for p in peers:
            if p["statecode"] in "*o" and p["refid"] != ".LOCL.":
                peer = p
                break
        if peer == None:
            if len(peers) == 0:
                return {"changed": False, "msg": "No NTP peers found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            return {"changed": False, "msg": "Found %d peers, but none is suitable" % len(peers), "data": {"state": "OK", "metrics": {}, "details": ""}}

        # Apply thresholds
        ntp_levels = params.get("ntp_levels", [10, 200.0, 500.0])
        stratum_crit = ntp_levels[0]
        offset_warn = ntp_levels[1]
        offset_crit = ntp_levels[2]

        # Offset check (upper levels)
        offset = peer["offset"]
        if offset >= offset_crit:
            state = "CRIT"
        elif offset >= offset_warn:
            state = "WARN"
        elif offset <= -offset_crit:
            state = "CRIT"
        elif offset <= -offset_warn:
            state = "WARN"
        else:
            state = "OK"

        # Stratum check (upper levels)
        stratum = peer["stratum"]
        if stratum >= stratum_crit:
            state = "CRIT"

        # Jitter check (no levels by default, but we must expose metric)
        jitter = peer["jitter"]

        # Time since last sync
        when = peer["when"]

        # State code mapping
        NTP_STATE_CODES = {
            "x": "falsetick",
            ".": "excess",
            "-": "outlyer",
            "+": "candidat",
            "#": "selected",
            "*": "sys.peer",
            "o": "pps-peer",
            "%": "discarded",
        }
        statecode = peer["statecode"]
        peer_state = NTP_STATE_CODES.get(statecode, "unknown")

        summary_parts = []
        summary_parts.append("Offset: %f ms" % offset)
        summary_parts.append("Stratum: %d" % stratum)
        summary_parts.append("Jitter: %f ms" % jitter)
        if when > 0:
            summary_parts.append("Last sync: %dm" % when)
        summary_parts.append("State: %s" % peer_state)
        summary = ", ".join(summary_parts)

        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": state,
                "metrics": {"offset": offset, "jitter": jitter, "stratum": stratum},
                "details": ""
            }
        }

    # Single peer mode
    peer = None
    for p in peers:
        if p["name"] == item:
            peer = p
            break
    if peer == None:
        return {"changed": False, "msg": "Peer %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if peer["reach"] == "0":
        return {"changed": False, "msg": "Peer %s is unreachable" % peer["name"], "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply thresholds
    ntp_levels = params.get("ntp_levels", [10, 200.0, 500.0])
    stratum_crit = ntp_levels[0]
    offset_warn = ntp_levels[1]
    offset_crit = ntp_levels[2]

    offset = peer["offset"]
    if offset >= offset_crit:
        state = "CRIT"
    elif offset >= offset_warn:
        state = "WARN"
    elif offset <= -offset_crit:
        state = "CRIT"
    elif offset <= -offset_warn:
        state = "WARN"
    else:
        state = "OK"

    stratum = peer["stratum"]
    if stratum >= stratum_crit:
        state = "CRIT"

    jitter = peer["jitter"]
    when = peer["when"]

    NTP_STATE_CODES = {
        "x": "falsetick",
        ".": "excess",
        "-": "outlyer",
        "+": "candidat",
        "#": "selected",
        "*": "sys.peer",
        "o": "pps-peer",
        "%": "discarded",
    }
    peer_state = NTP_STATE_CODES.get(peer["statecode"], "unknown")

    summary_parts = []
    summary_parts.append("Offset: %f ms" % offset)
    summary_parts.append("Stratum: %d" % stratum)
    summary_parts.append("Jitter: %f ms" % jitter)
    if when > 0:
        summary_parts.append("Last sync: %dm" % when)
    summary_parts.append("State: %s" % peer_state)
    summary = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"offset": offset, "jitter": jitter, "stratum": stratum},
            "details": ""
        }
    }