def main(ctx, params):
    # Run w32tm /query /status to get time service status
    res = ctx.run(["w32tm", "/query", "/status"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Windows time service not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse the output line by line, splitting on first ':'
    lines_raw = res.stdout.splitlines()
    data = {}
    for line in lines_raw:
        # Skip lines without colon (incomplete wrapped lines)
        if ":" not in line:
            continue
        # Split on first colon only
        key_val = line.split(":", 1)
        if len(key_val) < 2:
            continue
        key = key_val[0].strip()
        val = key_val[1].strip()
        data[key] = val

    # If service is not available, we may get only one error line
    # In our agent output, an error line appears as a single line without proper fields
    # We'll detect missing fields and treat as ErrorStatus equivalent
    if not data or "Last Successful Sync Time" not in data:
        # Fallback: if we have only one key with no colon split, use it as error message
        if len(data) == 1:
            err_msg = list(data.values())[0]
        else:
            err_msg = "Windows time service not available"
        return {
            "changed": False,
            "msg": err_msg,
            "data": {
                "state": "WARN",
                "metrics": {},
                "details": ""
            }
        }

    # Helper functions (no try/except allowed in Starlark — use guards)
    def parse_int_before_parens(s):
        if s == None:
            return None
        s = s.strip()
        if "(" in s:
            s = s.split("(")[0].strip()
        if not s:
            return None
        # Remove any non-digit suffix except possibly leading minus
        # e.g., "4 (secondary reference - syncd by (S)NTP)" -> "4"
        if s.startswith("0x"):
            # hex parsing using int(s,16) is not available in pure Starlark; use manual conversion
            hex_digits = "0123456789abcdefABCDEF"
            value = 0
            for c in s[2:]:
                if c in hex_digits:
                    value = value * 16 + hex_digits.find(c)
                else:
                    break
            return value
        # For integers (including negative)
        # Check if valid integer string
        if s.lstrip("-").isdigit() or (s.startswith("-") and s.lstrip("-").isdigit()):
            return int(s.split()[0])
        return None

    def parse_float_clean(s):
        if s == None:
            return None
        s = s.strip()
        if "(" in s:
            s = s.split("(")[0].strip()
        if not s:
            return None
        parts = s.split()
        if len(parts) == 0:
            return None
        s = parts[0]
        # Check for float (allow decimal point and optional sign)
        dot_count = s.count(".")
        if dot_count <= 1:
            # Strip sign and dots to validate digits
            candidate = s.replace(".", "", 1).lstrip("-")
            if candidate.isdigit():
                # Safe to convert
                if dot_count == 1:
                    return float(s)
                else:
                    return int(s)
        return None

    # Extract fields — defaults to None if missing
    leap_indicator = parse_int_before_parens(data.get("Leap Indicator", ""))
    stratum = parse_int_before_parens(data.get("Stratum", ""))
    precision = parse_int_before_parens(data.get("Precision", ""))
    root_delay = parse_float_clean(data.get("Root Delay", ""))
    root_dispersion = parse_float_clean(data.get("Root Dispersion", ""))
    reference_id = parse_int_before_parens(data.get("ReferenceId", ""))
    last_successful_sync_time = data.get("Last Successful Sync Time", "")
    source = data.get("Source", "")
    poll_interval = parse_int_before_parens(data.get("Poll Interval", ""))
    phase_offset = parse_float_clean(data.get("Phase Offset", ""))
    clock_rate = parse_float_clean(data.get("ClockRate", ""))
    state_machine = parse_int_before_parens(data.get("State Machine", ""))
    time_source_flags = parse_int_before_parens(data.get("Time Source Flags", ""))
    server_role = parse_int_before_parens(data.get("Server Role", ""))
    last_sync_error = parse_int_before_parens(data.get("Last Sync Error", ""))
    seconds_since_last_good_sync = parse_float_clean(data.get("Time since Last Good Sync Time", ""))

    # Default parameter values (Checkmk defaults)
    offset_warn, offset_crit = 0.2, 0.5  # fixed(0.2, 0.5) upper bound
    time_sync_warn = None
    time_sync_crit = None
    stratum_warn, stratum_crit = 5, 5     # fixed(5, 5)
    # States mapping (default: never_synced=WARN, no_data=WARN, stale_data=OK, time_diff_too_large=WARN, shutting_down=WARN)
    states_map = {
        "never_synced": 1,  # WARN (2)
        "no_data": 1,       # WARN
        "stale_data": 0,    # OK
        "time_diff_too_large": 1,  # WARN
        "shutting_down": 1  # WARN
    }
    # Apply custom states if present in params
    if "states" in params and params["states"]:
        s = params["states"]
        if "never_synced" in s: states_map["never_synced"] = s["never_synced"]
        if "no_data" in s: states_map["no_data"] = s["no_data"]
        if "stale_data" in s: states_map["stale_data"] = s["stale_data"]
        if "time_diff_too_large" in s: states_map["time_diff_too_large"] = s["time_diff_too_large"]
        if "shutting_down" in s: states_map["shutting_down"] = s["shutting_down"]

    # State machine interpretation (OK=1, HOLD=2, etc.)
    # Check: never synchronized if both state_machine==0 and reference_id==0
    state = "OK"
    notice = "Sync status: successful"

    # Handle potential None values safely
    if state_machine == 0 and reference_id == 0:
        st = "WARN" if states_map["never_synced"] else "OK"
        return {
            "changed": False,
            "msg": "Never synchronized (w32tm reported reference ID and state machine both 0)",
            "data": {
                "state": st,
                "metrics": {},
                "details": ""
            }
        }

    # Phase offset levels
    # Checkmk: levels_upper=(0.2,0.5), levels_lower=("-0.2","-0.5") effectively
    offset_ok = True
    if phase_offset != None:
        # Upper bound
        if phase_offset >= offset_crit:
            state = "CRIT"
            offset_ok = False
        elif phase_offset >= offset_warn:
            if state != "CRIT":
                state = "WARN"
            offset_ok = False
        # Lower bound (absolute value)
        elif -phase_offset >= offset_crit:
            state = "CRIT"
            offset_ok = False
        elif -phase_offset >= offset_warn:
            if state != "CRIT":
                state = "WARN"
            offset_ok = False

    # Time since last sync levels
    if seconds_since_last_good_sync != None:
        if time_sync_crit != None and seconds_since_last_good_sync >= time_sync_crit:
            if state != "CRIT":
                state = "CRIT"
        elif time_sync_warn != None and seconds_since_last_good_sync >= time_sync_warn:
            if state != "CRIT":
                state = "WARN"

    # Root dispersion and delay (notice only)
    # We'll ignore for state but keep in metrics

    # Stratum
    if stratum != None:
        if stratum >= stratum_crit:
            if state != "CRIT":
                state = "CRIT"
        elif stratum >= stratum_warn:
            if state != "CRIT":
                state = "WARN"

    # Last sync error mapping
    # 0=success, 1=no_data, 2=stale_data, 3=time_diff_too_large, 4=shutting_down
    if last_sync_error != None:
        if last_sync_error == 1:
            st = "WARN" if states_map["no_data"] else "OK"
            if st == "WARN" and state == "OK":
                state = "WARN"
        elif last_sync_error == 2:
            st = "OK" if states_map["stale_data"] else "WARN"
            # CRIT not possible in defaults
        elif last_sync_error == 3:
            st = "WARN" if states_map["time_diff_too_large"] else "OK"
            if st == "WARN" and state == "OK":
                state = "WARN"
        elif last_sync_error == 4:
            st = "WARN" if states_map["shutting_down"] else "OK"
            if st == "WARN" and state == "OK":
                state = "WARN"

    # Build metrics
    metrics = {}
    if phase_offset != None:
        metrics["time_offset"] = phase_offset
    if seconds_since_last_good_sync != None:
        metrics["time_since_last_successful_sync"] = seconds_since_last_good_sync
    if root_dispersion != None:
        metrics["root_dispersion"] = root_dispersion
    if root_delay != None:
        metrics["root_delay"] = root_delay
    if stratum != None:
        metrics["stratum"] = stratum

    # Message construction
    msg_parts = []
    if phase_offset != None:
        msg_parts.append("Offset: %fs" % phase_offset)
    if seconds_since_last_good_sync != None:
        msg_parts.append("Last sync: %fs ago" % seconds_since_last_good_sync)
    if source:
        msg_parts.append("Source: " + source.split(",")[0])
    if root_dispersion != None:
        msg_parts.append("Root dispersion: %fs" % root_dispersion)
    if root_delay != None:
        msg_parts.append("Root delay: %fs" % root_delay)
    if stratum != None:
        msg_parts.append("Stratum: %d" % stratum)

    if not msg_parts:
        msg_parts.append("Windows time service status OK")
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
