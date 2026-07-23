def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"levels": (80.0, 90.0)}, "metrics": ["filehandler_perc"]}]}
        }

    # Read /proc/sys/fs/file-nr
    if not ctx.file_exists("/proc/sys/fs/file-nr"):
        return {
            "changed": False,
            "msg": "cannot read /proc/sys/fs/file-nr",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    content = ctx.file_read("/proc/sys/fs/file-nr")
    lines = content.split("\n")
    if len(lines) == 0 or lines[0].strip() == "":
        return {
            "changed": False,
            "msg": "empty /proc/sys/fs/file-nr",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    fields = lines[0].split()
    if len(fields) < 3:
        return {
            "changed": False,
            "msg": "unexpected format in /proc/sys/fs/file-nr: expected at least 3 fields",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard: verify each field is a valid integer string before conversion
    valid = True
    for field in fields[:3]:
        stripped = field.strip()
        # Handle possible leading sign? No, file-nr has non-negative integers
        valid = valid and (stripped.isdigit() or (len(stripped) > 0 and stripped[0] == '-' and stripped[1:].isdigit()))
        if not valid:
            break
    if not valid:
        return {
            "changed": False,
            "msg": "cannot parse numeric values from /proc/sys/fs/file-nr",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    allocated = int(fields[0])
    # used_or_unused = int(fields[1])  # not needed for this check
    maximum = int(fields[2])

    if maximum == 0:
        return {
            "changed": False,
            "msg": "maximum file handles is zero",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Compute percentage
    perc = float(allocated) / float(maximum) * 100.0

    # Apply levels
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]

    # Determine state: warn if >= warn%, crit if >= crit%
    if perc >= crit:
        state = "CRIT"
    elif perc >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "(%d of %d file handles)" % (allocated, maximum),
        "data": {
            "state": state,
            "metrics": {"filehandler_perc": perc},
            "details": ""
        }
    }
