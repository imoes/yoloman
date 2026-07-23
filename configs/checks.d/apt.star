NOTHING_PENDING_FOR_INSTALLATION = "No updates pending for installation"
ESM_NOT_ENABLED = "Enable UA Infra"
ESM_ENABLED = "ESM service enabled"
UBUNTU_PRO = "Ubuntu Pro"

SECURITY_REGEX_SUBSTRINGS = ["Debian-Security:", "Ubuntu", "-security"]


def _is_security_update(metadata):
    if metadata == None:
        return False
    for s in SECURITY_REGEX_SUBSTRINGS:
        if s in metadata:
            if s == "Ubuntu":
                # Must contain / and -security to be a real security update
                parts = metadata.split()
                for part in parts:
                    if "-security" in part:
                        return True
                return False
            return True
    return False


def _parse_line(line):
    # Inst|Remv package [old_version] (new_version metadata)
    if not (line.startswith("Inst ") or line.startswith("Remv ")):
        return None
    parts = line.split(None, 2)
    action = parts[0]
    if len(parts) < 2:
        return None
    package = parts[1]
    old_version = None
    update_metadata = None
    if len(parts) > 2:
        rest = parts[2]
        # Extract [old_version] if present
        if rest.startswith("["):
            idx = rest.find("]")
            if idx != -1:
                old_version = rest[1:idx]
                rest = rest[idx+1:].strip()
        # Extract (new_version metadata) if present
        if rest.startswith("("):
            idx = rest.find(")")
            if idx != -1:
                update_metadata = rest[1:idx]
    return {"action": action, "package": package, "old_version": old_version, "update_metadata": update_metadata}


def _sanitize_string_table(lines):
    sanitized = []
    skip_next = 0
    for i in range(len(lines)):
        if skip_next > 0:
            skip_next -= 1
            continue
        line = lines[i]
        if line.startswith(UBUNTU_PRO):
            skip_next = 1
            continue
        if line.startswith(ESM_ENABLED):
            skip_next = 3
            continue
        sanitized.append(line)
    return sanitized


def main(ctx, params):
    if params.get("_discover"):
        # Single service discovery
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["normal_updates", "removals", "security_updates"]}]}}

    # Read apt section from agent
    res = ctx.run(["cat", "/var/lib/update-notifier/updates-available"], mutates=False)
    lines = res.stdout.splitlines()

    if not lines:
        # No apt data available
        return {"changed": False, "msg": "No apt data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Sanitize the string table
    sanitized_lines = _sanitize_string_table(lines)

    if len(sanitized_lines) == 0:
        return {"changed": False, "msg": NOTHING_PENDING_FOR_INSTALLATION,
                "data": {"state": "OK", "metrics": {"normal_updates": 0, "removals": 0, "security_updates": 0}, "details": ""}}

    # Handle ESM not enabled case
    if ESM_NOT_ENABLED in sanitized_lines[0]:
        return {"changed": False, "msg": "System could receive security updates, but needs extended support license",
                "data": {"state": "CRIT", "metrics": {"normal_updates": 0, "removals": 0, "security_updates": 0}, "details": ""}}

    # Check if data is valid (first line must be Inst/Remv or "No updates pending")
    if sanitized_lines[0] == NOTHING_PENDING_FOR_INSTALLATION:
        return {"changed": False, "msg": NOTHING_PENDING_FOR_INSTALLATION,
                "data": {"state": "OK", "metrics": {"normal_updates": 0, "removals": 0, "security_updates": 0}, "details": ""}}

    parsed = _parse_line(sanitized_lines[0])
    if parsed == None or (parsed["old_version"] == None and parsed["update_metadata"] == None):
        return {"changed": False, "msg": "Invalid apt data",
                "data": {"state": "UNKNOWN", "metrics": {"normal_updates": 0, "removals": 0, "security_updates": 0}, "details": ""}}

    updates = []
    removals = []
    sec_updates = []

    for line in sanitized_lines:
        if line.startswith(UBUNTU_PRO) or line.startswith(ESM_ENABLED) or line.startswith(ESM_NOT_ENABLED):
            continue
        parsed = _parse_line(line)
        if parsed == None:
            continue
        if parsed["action"] == "Remv":
            removals.append(parsed["package"])
        elif parsed["action"] == "Inst":
            if _is_security_update(parsed["update_metadata"]):
                sec_updates.append(parsed["package"])
            else:
                updates.append(parsed["package"])

    # Get thresholds from params
    normal = params.get("normal", 1)  # 1=warning, 2=critical, 0=ok
    removals_threshold = params.get("removals", 1)
    security = params.get("security", 2)

    # Determine state
    if len(updates) > 0:
        state = "CRIT" if normal == 2 else "WARN"
    elif len(sec_updates) > 0:
        state = "CRIT" if security == 2 else "WARN"
    elif len(removals) > 0:
        state = "CRIT" if removals_threshold == 2 else "WARN"
    else:
        state = "OK"

    # Build summary message
    parts = []
    if updates:
        parts.append("%d normal updates" % len(updates))
    if removals:
        parts.append("%d auto removals (%s)" % (len(removals), ", ".join(removals)))
    if sec_updates:
        parts.append("%d security updates (%s)" % (len(sec_updates), ", ".join(sec_updates)))

    if len(updates) == 0 and len(removals) == 0 and len(sec_updates) == 0:
        msg = NOTHING_PENDING_FOR_INSTALLATION
    else:
        msg = "; ".join(parts)

    # Return verdict
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"normal_updates": len(updates), "removals": len(removals), "security_updates": len(sec_updates)}, "details": ""}}
