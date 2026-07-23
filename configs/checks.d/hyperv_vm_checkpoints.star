# Helper to parse date strings using multiple locale formats
# Returns (age_seconds, name) if parsed successfully, else None
def _parse_checkpoint_age(created_str, name, current_time):
    formats = [
        "%m/%d/%Y %H:%M:%S",
        "%d/%m/%Y %H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%d.%m.%Y %H:%M:%S",
        "%Y/%m/%d %H:%M:%S",
        "%m-%d-%Y %H:%M:%S",
        "%d-%m-%Y %H:%M:%S",
        "%m/%d/%Y %I:%M:%S %p",
        "%d/%m/%Y %I:%M:%S %p",
        "%m/%d/%y %H:%M:%S",
        "%d/%m/%y %H:%M:%S",
    ]
    for fmt in formats:
        # Attempt parse with current format
        parts = created_str.split(" ")
        if len(parts) != 2:
            continue
        date_part = parts[0]
        time_part = parts[1]
        # Handle AM/PM
        hour_offset = 0
        if len(parts) == 3:
            ampm = parts[2].upper()
            if ampm == "PM":
                hour_offset = 12
        # Parse date
        date_parts = date_part.split("/")
        if len(date_parts) != 3:
            continue
        # Determine format by separators and length
        sep = "/"
        if "." in date_part:
            sep = "."
        elif "-" in date_part:
            sep = "-"
        d_parts = date_part.split(sep)
        if len(d_parts) != 3:
            continue
        # Try to parse
        y = int(d_parts[2]) if len(d_parts[2]) == 4 else int(d_parts[2]) + 2000 if len(d_parts[2]) == 2 else 0
        m = int(d_parts[0]) if sep == "/" else int(d_parts[1])
        d = int(d_parts[1]) if sep == "/" else int(d_parts[0])
        time_parts = time_part.split(":")
        if len(time_parts) != 3:
            continue
        h = int(time_parts[0])
        if "PM" in created_str.upper() and h < 12:
            h = h + 12
        elif "AM" in created_str.upper() and h == 12:
            h = 0
        mi = int(time_parts[1])
        s = int(time_parts[2])
        # Convert to timestamp using a simple algorithm (ignoring DST etc)
        days = _days_since_epoch(y, m, d)
        seconds = days * 86400 + h * 3600 + mi * 60 + s
        age = current_time - seconds
        return (name, age)
    return None

# Simple days since epoch approximation (Gregorian calendar)
def _days_since_epoch(y, m, d):
    # Adjust month and year for calculation
    if m <= 2:
        y = y - 1
        m = m + 12
    # Calculate days
    a = y // 100
    b = a // 4
    c = 2 - a + b
    e = int(365.25 * (y + 4716))
    f = int(30.6001 * (m + 1))
    return c + d + e + f - 1524

def main(ctx, params):
    current_time = ctx.run(["date", "+%s"], mutates=False).stdout.strip()
    if not current_time:
        current_time = "0"
    if not current_time.isdigit():
        current_time = "0"
    current_time = int(current_time)

    # Read agent section from standard Checkmk agent path (if present) or fallback
    # The agent section is typically embedded in the agent output as <<<hyperv_vm_checkpoints>>>
    # Since we don't have the agent binary, we must look for the same data source:
    # Checkmk's Windows agent reads this via PowerShell: Get-VM | Get-VMSnapshot
    # We emulate this by running PowerShell to get snapshots.
    # Note: On Linux this check is not applicable — return empty discovery.
    os_family = ctx.facts().get("os_family", "")
    if os_family != "windows":
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "not supported on non-Windows systems",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Run PowerShell to get VM checkpoints
    res = ctx.run(["powershell", "-NoProfile", "-Command",
        "Get-VM | Get-VMSnapshot | Select-Object Name, Path, Created, ParentSnapshotName | ConvertTo-Json -Depth 3"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        # Fallback: try WMI query
        res = ctx.run(["powershell", "-NoProfile", "-Command",
            "Get-WmiObject -Namespace root\\virtualization\\v2 -Query 'Select * From Msvm_VirtualSystemSettingData Where VirtualSystemType=3' | Select-Object -Property Caption,ElementName,CreationTime,ParentSnapshotName | ConvertTo-Json -Depth 3"], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "no checkpoint data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse JSON
    checkpoints_json = json.decode(res.stdout)
    checkpoints = []
    if type(checkpoints_json) == "list":
        for item in checkpoints_json:
            name = item.get("ElementName", item.get("Name", ""))
            path = item.get("Path", "")
            created = item.get("CreationTime", item.get("Created", ""))
            parent = item.get("ParentSnapshotName", "")
            if created != None and name != "":
                checkpoints.append({
                    "name": str(name),
                    "path": str(path) if path else "",
                    "created": str(created),
                    "parent": str(parent) if parent else ""
                })
    # If not a list, try single item
    elif type(checkpoints_json) == "dict":
        name = checkpoints_json.get("ElementName", checkpoints_json.get("Name", ""))
        path = checkpoints_json.get("Path", "")
        created = checkpoints_json.get("CreationTime", checkpoints_json.get("Created", ""))
        parent = checkpoints_json.get("ParentSnapshotName", "")
        if created != None and name != "":
            checkpoints.append({
                "name": str(name),
                "path": str(path) if path else "",
                "created": str(created),
                "parent": str(parent) if parent else ""
            })

    # Discovery mode
    if params.get("_discover"):
        if checkpoints:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["age", "age_oldest"]}
                ]}
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }

    # Check mode
    item = params.get("item", "")
    if item != "":
        # This is a single-service check; no per-item breakdown.
        # Return unknown if item specified but not matching (shouldn't happen in practice)
        return {
            "changed": False,
            "msg": "no such item",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if not checkpoints:
        return {
            "changed": False,
            "msg": "Checkpoints: 0",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    # Parse ages
    checkpoint_data = []
    for cp in checkpoints:
        created_str = cp.get("created", "")
        name = cp.get("name", "")
        if created_str == "" or name == "":
            continue
        # Remove timezone suffix if present (e.g. +02:00)
        if "+" in created_str:
            created_str = created_str.split("+")[0]
        elif "-" in created_str and created_str.count("-") > 2:
            # Handle ISO-like negative offset
            created_str = created_str.split("-")[:-1]
            created_str = "-".join(created_str)
        # Call our helper
        parsed = _parse_checkpoint_age(created_str.strip(), name, current_time)
        if parsed != None:
            checkpoint_data.append(parsed)

    if not checkpoint_data:
        return {
            "changed": False,
            "msg": "No valid checkpoint dates found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Sort by age (youngest first)
    checkpoint_data.sort(key=lambda x: x[1])

    newest = checkpoint_data[0]
    oldest = max(checkpoint_data, key=lambda x: x[1])

    newest_name, newest_age = newest
    oldest_name, oldest_age = oldest

    # Threshold defaults
    SECONDS_PER_DAY = 86400
    age_levels = ("no_levels", None)
    age_oldest_levels = ("fixed", (10 * SECONDS_PER_DAY, 20 * SECONDS_PER_DAY))

    # Extract from params if present
    if params.get("age") != None and type(params.get("age")) == "list":
        age_levels = params.get("age")
    if params.get("age_oldest") != None and type(params.get("age_oldest")) == "list":
        age_oldest_levels = params.get("age_oldest")

    # Determine state based on levels
    def _state_from_levels(value, levels):
        if type(levels) == "list" and levels[0] == "no_levels":
            return "OK"
        if type(levels) == "list" and levels[0] == "fixed":
            warn, crit = levels[1]
            if value >= crit:
                return "CRIT"
            if value >= warn:
                return "WARN"
        return "OK"

    newest_state = _state_from_levels(newest_age, age_levels)
    oldest_state = _state_from_levels(oldest_age, age_oldest_levels)

    # Pick worst state
    state = "OK"
    if newest_state == "CRIT" or oldest_state == "CRIT":
        state = "CRIT"
    elif newest_state == "WARN" or oldest_state == "WARN":
        state = "WARN"

    # Build summary
    summary = "Checkpoints: %d" % len(checkpoint_data)
    if type(age_levels) == "list" and age_levels[0] == "fixed":
        summary = summary + ", Last (%s)" % newest_name + ": %d s" % int(newest_age)
    if type(age_oldest_levels) == "list" and age_oldest_levels[0] == "fixed":
        summary = summary + ", Oldest (%s)" % oldest_name + ": %d s" % int(oldest_age)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "age": int(newest_age),
                "age_oldest": int(oldest_age)
            },
            "details": ""
        }
    }