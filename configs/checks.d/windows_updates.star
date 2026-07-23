# ===== translated check plugin: windows_updates =====

# Checkmk check default parameters (used when params.get() returns None)
DEFAULT_LEVELS_IMPORTANT = (1, 1)
DEFAULT_LEVELS_OPTIONAL = (1, 99)
DEFAULT_LEVELS_LOWER_FORCED_REBOOT = (604800, 172800)
DEFAULT_REBOOT_REQUIRED_SHOW_STATE = 1

def _state_from_level(value, levels, lower=False):
    """Return (state_code, state_name) based on levels comparison.
    
    levels: (warn, crit)
    lower=False: WARN if value >= warn, CRIT if value >= crit
    lower=True:  WARN if value <= warn, CRIT if value <= crit
    """
    warn, crit = levels
    if lower:
        if value <= crit:
            return 2, "CRIT"
        if value <= warn:
            return 1, "WARN"
    else:
        if value >= crit:
            return 2, "CRIT"
        if value >= warn:
            return 1, "WARN"
    return 0, "OK"


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: always yield one service
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "levels_important": list(DEFAULT_LEVELS_IMPORTANT),
                            "levels_optional": list(DEFAULT_LEVELS_OPTIONAL),
                            "levels_lower_forced_reboot": list(DEFAULT_LEVELS_LOWER_FORCED_REBOOT),
                            "reboot_required_show_state": DEFAULT_REBOOT_REQUIRED_SHOW_STATE,
                        },
                        "metrics": ["important", "optional"]
                    }
                ]
            },
        }

    # Check mode
    # We expect the agent to expose the section data via a special key or file.
    # Since Checkmk agents produce raw agent output, read the agent section directly.
    # We'll use the standard checkmk Windows agent section: [windows_updates]
    # For compatibility, read from the agent output file or use cmk's discovery.
    # However, Starlark agent has no direct access to agent sections.
    # Workaround: call `cmk` to get JSON agent output for this section.
    # But the Starlark agent only allows ctx.run() and ctx.file_read().
    # We'll use the agent output format directly: /var/lib/checkmk-agent/raw/... or /var/lib/checkmk/...
    # Since this is Checkmk 2.x style, we use agent output format from:
    #   /var/lib/checkmk-agent/agent-output/windows_updates
    # If not found, fallback to reading raw output from a known path.

    section_path = "/var/lib/checkmk-agent/agent-output/windows_updates"
    if not ctx.file_exists(section_path):
        section_path = "/var/lib/checkmk/agent-output/windows_updates"
        if not ctx.file_exists(section_path):
            # Last resort: return UNKNOWN since section is unavailable.
            return {
                "changed": False,
                "msg": "windows_updates section not found",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "",
                },
            }

    content = ctx.file_read(section_path).strip()
    lines = content.splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "windows_updates section is empty",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse the section
    # Format: 
    # Line 0: <reboot_required> <important_count> <optional_count>
    # Line 1+: update lists + forced_reboot timestamp
    # Example:
    # 0 2 1
    # KB5012345; KB5023456
    # KB4012345
    # 2025-04-01 12:00:00

    header = lines[0].split()
    if len(header) != 3:
        return {
            "changed": False,
            "msg": "windows_updates header malformed: expected 3 fields",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    reboot_required_flag = header[0]
    if reboot_required_flag == "x":
        # Failed section
        reason = "unknown"
        if len(lines) > 1:
            reason = lines[1]
        return {
            "changed": False,
            "msg": reason,
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": "",
            },
        }

    # Parse integers with guards
    reboot_required = reboot_required_flag == "1"
    important_count = int(header[1]) if header[1].isdigit() else -1
    optional_count = int(header[2]) if header[2].isdigit() else -1

    if important_count < 0 or optional_count < 0:
        return {
            "changed": False,
            "msg": "windows_updates header integers invalid",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Extract update lists
    important_updates = []
    optional_updates = []
    forced_reboot = None

    if important_count > 0 and len(lines) > 1:
        important_line = lines[1]
        important_updates = [u.strip() for u in important_line.split(";") if u.strip()]

    optional_offset = 1 + (1 if important_count > 0 else 0)
    if optional_count > 0 and len(lines) > optional_offset:
        optional_line = lines[optional_offset]
        optional_updates = [u.strip() for u in optional_line.split(";") if u.strip()]

    forced_reboot_offset = optional_offset + (1 if optional_count > 0 else 0)
    if len(lines) > forced_reboot_offset:
        # Parse forced_reboot timestamp: "YYYY-MM-DD HH:MM:SS"
        ts_str = lines[forced_reboot_offset].strip()
        parts = ts_str.split(" ")
        if len(parts) == 2:
            date_part = parts[0].split("-")
            time_part = parts[1].split(":")
            if len(date_part) == 3 and len(time_part) == 3:
                # Check all parts are numeric
                year_str = date_part[0]
                month_str = date_part[1]
                day_str = date_part[2]
                hour_str = time_part[0]
                minute_str = time_part[1]
                second_str = time_part[2]
                # Validate numeric
                year_ok = len(year_str) == 4 and year_str.isdigit()
                month_ok = len(month_str) == 2 and month_str.isdigit()
                day_ok = len(day_str) == 2 and day_str.isdigit()
                hour_ok = len(hour_str) == 2 and hour_str.isdigit()
                minute_ok = len(minute_str) == 2 and minute_str.isdigit()
                second_ok = len(second_str) == 2 and second_str.isdigit()
                if year_ok and month_ok and day_ok and hour_ok and minute_ok and second_ok:
                    year = int(year_str)
                    month = int(month_str)
                    day = int(day_str)
                    hour = int(hour_str)
                    minute = int(minute_str)
                    second = int(second_str)
                    # Approximate mktime: use seconds since epoch (ignoring leap seconds)
                    # For simplicity, assume UTC and use a basic calculation
                    # This is approximate but sufficient for time-based thresholds
                    days_in_month = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
                    if (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0):
                        days_in_month[1] = 29
                    days = 0
                    for y in range(1970, year):
                        if (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0):
                            days += 366
                        else:
                            days += 365
                    for m in range(month - 1):
                        days += days_in_month[m]
                    days += day - 1
                    forced_reboot = days * 86400 + hour * 3600 + minute * 60 + second

    # Now run the check logic
    levels_important = params.get("levels_important", DEFAULT_LEVELS_IMPORTANT)
    levels_optional = params.get("levels_optional", DEFAULT_LEVELS_OPTIONAL)
    levels_lower_forced_reboot = params.get("levels_lower_forced_reboot", DEFAULT_LEVELS_LOWER_FORCED_REBOOT)
    reboot_required_show_state_param = params.get("reboot_required_show_state", DEFAULT_REBOOT_REQUIRED_SHOW_STATE)

    # Determine states and metrics
    state = "OK"
    metrics = {"important": len(important_updates), "optional": len(optional_updates)}
    msg_parts = []
    details = []

    # Important updates
    imp_state_code, imp_state_name = _state_from_level(len(important_updates), levels_important)
    if imp_state_name != "OK":
        state = imp_state_name
    if len(important_updates) > 0:
        msg_parts.append("Important: %d" % len(important_updates))
        details.append("; ".join(important_updates))

    # Optional updates
    opt_state_code, opt_state_name = _state_from_level(len(optional_updates), levels_optional)
    if opt_state_name != "OK" and state == "OK":
        state = opt_state_name
    if len(optional_updates) > 0:
        msg_parts.append("Optional: %d" % len(optional_updates))
        details.append("; ".join(optional_updates))

    # Reboot required
    reboot_required_show_state = None
    if reboot_required_show_state_param == 0:
        reboot_required_show_state = "OK"
    elif reboot_required_show_state_param == 1:
        reboot_required_show_state = "WARN"
    elif reboot_required_show_state_param == 2:
        reboot_required_show_state = "CRIT"
    elif reboot_required_show_state_param == 3:
        reboot_required_show_state = "UNKNOWN"
    else:
        reboot_required_show_state = "UNKNOWN"

    if reboot_required and reboot_required_show_state != None:
        if reboot_required_show_state != "OK" and state == "OK":
            state = reboot_required_show_state
        msg_parts.append("Reboot required")
        details.append("Reboot required to finish updates")

    # Forced reboot time check
    if forced_reboot != None:
        # Get current time: call `date +%s`
        res_now = ctx.run(["date", "+%s"], mutates=False)
        if res_now.rc == 0:
            now_str = res_now.stdout.strip()
            if now_str.isdigit():
                now = int(now_str)
                delta = forced_reboot - now
                lower_warn, lower_crit = levels_lower_forced_reboot
                # For lower levels: WARN if delta <= warn, CRIT if delta <= crit (since crit < warn for lower)
                # But Checkmk defaults: (604800, 172800) meaning warn at 7 days, crit at 2 days
                # So if delta <= 172800 -> CRIT, delta <= 604800 -> WARN
                if delta <= lower_crit:
                    if state == "OK":
                        state = "CRIT"
                    msg_parts.append("Forced reboot time: CRIT (low)")
                    details.append("Forced reboot in " + str(int(delta)) + " sec")
                elif delta <= lower_warn:
                    if state == "OK":
                        state = "WARN"
                    msg_parts.append("Forced reboot time: WARN")
                    details.append("Forced reboot in " + str(int(delta)) + " sec")
                else:
                    # Within tolerance
                    pass

    # Build final message
    final_msg = ", ".join(msg_parts) if msg_parts else "No updates pending"

    return {
        "changed": False,
        "msg": final_msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": " | ".join(details),
        },
    }
