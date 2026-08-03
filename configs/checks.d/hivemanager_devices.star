# ===== Checkmk check → read-only Starlark check module =====
# Translates cmk/plugins/hivemanager/agent_based/hivemanager_devices.py
# Monitors Aruba/HP HiveManager devices via the hivemanager_devices agent section.

# Default parameters (mirrors Checkmk check_default_parameters)
DEFAULT_PARAMS = {
    "alert_on_loss": True,
    "max_clients": (25, 50),
    "crit_states": ["Critical"],
    "warn_states": ["Maybe", "Major", "Minor"],
}

# Keys considered "additional information" in the summary (order preserved)
ADDITIONAL_INFORMATION = [
    "eth0LLDPPort",
    "eth0LLDPSysName",
    "hive",
    "hiveOS",
    "hwmodel",
    "serialNumber",
    "nodeId",
    "location",
    "networkPolicy",
]

# Token multipliers for parsing Checkmk-style durations (unused here; uptime
# is stored as raw seconds-equivalent tokens in the section).
TOKEN_MULTIPLIER = (1, 60, 3600, 86400, 31536000)


def _parse_hivemanager_devices(raw):
    """Parse the raw hivemanager_devices section into a dict keyed by hostName.

    Each raw line is expected to be a list of "key::value" tokens. We group
    consecutive lines into per-device info dicts. Lines starting a new
    hostName (containing hostName::) begin a new entry.
    """
    section = {}
    for line in raw:
        # line is a list of "key::value" strings from the agent section
        infos = {}
        for token in line:
            # Split on the FIRST "::" only
            idx = token.find("::")
            if idx == -1:
                continue
            key = token[:idx]
            value = token[idx + 2:]
            infos[key] = value
        # The hostName key identifies the device item
        host = infos.get("hostName")
        if host == None:
            continue
        section[host] = infos
    return section


def _gather_section(ctx):
    """Read the real on-host source for hivemanager_devices.

    The Checkmk agent plugin reads from a HiveManager API/socket. Since our
    agent may not have that, we support reading a local cache file written
    by an external collector at /var/lib/cmk/hivemanager_devices (one
    device per line, "key::value" tokens separated by spaces). If absent,
    the check does not apply.
    """
    path = "/var/lib/cmk/hivemanager_devices"
    if not ctx.file_exists(path):
        return None
    content = ctx.file_read(path)
    raw = []
    for line in content.splitlines():
        line = line.strip()
        if line == "":
            continue
        raw.append(line.split())
    return _parse_hivemanager_devices(raw)


def _probe(ctx):
    """Determine whether hivemanager monitoring is actually present on host."""
    path = "/var/lib/cmk/hivemanager_devices"
    return ctx.file_exists(path)


def _parse_uptime_tokens(tokens):
    """Convert Checkmk timespan tokens like [3, 'day', 5, 'hour', ...] to seconds.

    The original code uses:
        sum(factor * int(token) for factor, token in
            zip(TOKEN_MULTIPLIER, raw_uptime.split()[-2::-2]))
    raw_uptime split is e.g. ['3','day','5','hour','10','minute','down' or 'up']
    reversed and stepped by 2 yields the numeric tokens in ascending unit order.
    We reconstruct using the same logic.
    """
    # tokens: list like [n_days, 'day', n_hours, 'hour', ..., 'up'/'down']
    # Original: raw.split()[-2::-2] -> take every 2nd from end-1 going backwards
    # Build the reversed token list, then pick every other starting at index 0
    # of the reversed list minus the last (state) element.
    if tokens == None or len(tokens) == 0:
        return 0
    # Drop trailing state word if present
    body = tokens
    if body[-1] in ("up", "down"):
        body = body[:-1]
    # Original: split()[-2::-2] on the full string; replicate:
    # reversed list, then take indices 0,2,4,... (which equals [-2::-2] reversed)
    rev = list(reversed(body))
    nums = []
    i = 0
    for t in rev:
        if i % 2 == 0:
            # numeric token
            n = int(t) if t.lstrip("-").isdigit() else 0
            nums.append(n)
        i += 1
    # nums are in ascending unit order: days, hours, minutes, seconds
    # but we need to multiply by TOKEN_MULTIPLIER in ascending order
    total = 0
    for factor, n in zip(TOKEN_MULTIPLIER, nums):
        total += factor * n
    return total


def _check_levels(value, levels, name, human_readable):
    """Mimic cmk check_levels_legacy_compatible for warn/crit thresholds.

    levels is (warn, crit) or params.get("max_uptime"). Values that fail
    the upper-level comparison grade as WARN/CRIT.
    """
    if levels == None:
        return "OK", ""
    warn = levels[0]
    crit = levels[1]
    # warn/crit may be None
    if crit != None and value >= crit:
        return "CRIT", "%s %s (crit at %s)" % (name, human_readable(value), human_readable(crit))
    if warn != None and value >= warn:
        return "WARN", "%s %s (warn at %s)" % (name, human_readable(value), human_readable(warn))
    return "OK", "%s %s" % (name, human_readable(value))


def _render_timespan(seconds):
    """Render a number of seconds like Checkmk render.timespan."""
    if seconds == None:
        return "-"
    if seconds < 0:
        return "-"
    days = seconds // 86400
    seconds = seconds % 86400
    hours = seconds // 3600
    seconds = seconds % 3600
    minutes = seconds // 60
    secs = seconds % 60
    parts = []
    if days > 0:
        parts.append("%d day%s" % (days, "s" if days != 1 else ""))
    if hours > 0:
        parts.append("%d hour%s" % (hours, "s" if hours != 1 else ""))
    if minutes > 0:
        parts.append("%d minute%s" % (minutes, "s" if minutes != 1 else ""))
    if secs > 0 or len(parts) == 0:
        parts.append("%d second%s" % (secs, "s" if secs != 1 else ""))
    return " ".join(parts)


def main(ctx, params):
    # ----- DISCOVERY MODE -----
    if params.get("_discover"):
        if not _probe(ctx):
            return {
                "changed": False,
                "msg": "hivemanager_devices not installed on this host",
                "data": {"discovery": []},
            }
        section = _gather_section(ctx)
        if section == None or len(section) == 0:
            return {
                "changed": False,
                "msg": "no hivemanager devices found",
                "data": {"discovery": []},
            }
        discovery = []
        for host_name in section:
            discovery.append({
                "item": host_name,
                "params": dict(DEFAULT_PARAMS),
                "metrics": ["client_count"],
            })
        return {
            "changed": False,
            "msg": "discovered %d hivemanager devices" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ----- CHECK MODE -----
    item = params.get("item", "")
    merged = dict(DEFAULT_PARAMS)
    merged.update(params)

    if not _probe(ctx):
        return {
            "changed": False,
            "msg": "hivemanager_devices not installed on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _gather_section(ctx)
    if section == None:
        return {
            "changed": False,
            "msg": "hivemanager_devices section not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    infos = section.get(item)
    if infos == None:
        return {
            "changed": False,
            "msg": "no such hivemanager device: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # ---- Alarm state ----
    state = "OK"
    summaries = []

    alarm = infos.get("alarm", "")
    alarmstate = "Alarm state: " + alarm
    crit_states = merged.get("crit_states", DEFAULT_PARAMS["crit_states"])
    warn_states = merged.get("warn_states", DEFAULT_PARAMS["warn_states"])
    if alarm in crit_states:
        state = "CRIT"
        summaries.append(alarmstate)
    elif alarm in warn_states:
        if state == "OK":
            state = "WARN"
        summaries.append(alarmstate)

    # ---- Lost connection ----
    alert_on_loss = merged.get("alert_on_loss", True)
    if alert_on_loss:
        conn = infos.get("connection", "True")
        if conn == "False":
            if state == "OK":
                state = "CRIT"
            summaries.append("Connection lost")

    # ---- Client count ----
    clients_raw = infos.get("clients", "0")
    number_of_clients = int(clients_raw) if clients_raw.lstrip("-").isdigit() else 0
    max_clients = merged.get("max_clients", DEFAULT_PARAMS["max_clients"])
    warn_c = max_clients[0] if max_clients != None and len(max_clients) >= 2 else None
    crit_c = max_clients[1] if max_clients != None and len(max_clients) >= 2 else None

    infotext = "Clients: %d" % number_of_clients
    levels_text = " Warn/Crit at %s/%s" % (warn_c, crit_c)

    if crit_c != None and number_of_clients >= crit_c:
        if state == "OK":
            state = "CRIT"
        summaries.append(infotext + levels_text)
    elif warn_c != None and number_of_clients >= warn_c:
        if state == "OK":
            state = "WARN"
        summaries.append(infotext + levels_text)
    else:
        summaries.append(infotext)

    # ---- Uptime ----
    max_uptime = merged.get("max_uptime")
    up_raw = infos.get("upTime", "down")
    if up_raw != "down":
        up_tokens = up_raw.split()
        up_seconds = _parse_uptime_tokens(up_tokens)
        up_state, up_msg = _check_levels(
            up_seconds, max_uptime, "Uptime", _render_timespan
        )
        if up_state == "CRIT":
            if state == "OK":
                state = "CRIT"
        elif up_state == "WARN":
            if state == "OK":
                state = "WARN"
        if up_msg != "":
            summaries.append(up_msg)
    else:
        summaries.append("Uptime: down")

    # ---- Additional information ----
    add_parts = []
    for key in ADDITIONAL_INFORMATION:
        val = infos.get(key)
        if val != None and val != "-":
            add_parts.append("%s: %s" % (key, val))
    if len(add_parts) > 0:
        summaries.append(", ".join(add_parts))

    msg = "; ".join(summaries)
    metrics = {"client_count": number_of_clients}

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": msg,
        },
    }