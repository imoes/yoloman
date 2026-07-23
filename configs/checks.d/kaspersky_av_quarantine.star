def main(ctx, params):
    # Read the agent section data: the checkmk agent writes
    # <<<kaspersky_av_quarantine:sep(58)>>>
    # so we expect a text file with colon-separated key: value lines.
    # Since we have no access to the Checkmk agent, we read the same
    # underlying source the agent plugin would: the quarantine log file
    # produced by Kaspersky Endpoint Security for Linux.
    #
    # The Checkmk source parses lines like:
    #   Objects: 0
    #   Size: 0
    #   Last added: unknown
    #
    # We try common locations where Kaspersky might place this info.

    section = {}
    # Try the most likely path used by Kaspersky CLI tools
    path = "/var/lib/kaspersky/kesl/av_quarantine_stats.txt"
    if ctx.file_exists(path):
        content = ctx.file_read(path)
        for line in content.splitlines():
            parts = line.split(":", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                value = parts[1].strip()
                section[key] = value

    # Fallback: parse stdout from kavcontrol if present (read-only)
    if not section:
        res = ctx.run(["kavcontrol", "--quarantine", "info"], mutates=False)
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.split(":", 1)
                if len(parts) == 2:
                    key = parts[0].strip()
                    value = parts[1].strip()
                    section[key] = value

    # Discovery mode: yield a single service if we have any section data
    if params.get("_discover"):
        if section:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["Objects"]}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []},
        }

    # Check mode: single service (item is always "")
    if not section:
        return {
            "changed": False,
            "msg": "no quarantine data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    objects_str = section.get("Objects", "0")
    if objects_str == None:
        objects = 0
    else:
        objects = int(objects_str.strip()) if objects_str.strip().lstrip("-").isdigit() else 0

    state = "CRIT" if objects > 0 else "OK"
    summary = "%d Objects in Quarantine, Last added: %s" % (
        objects,
        section.get("Last added", "unknown").strip(),
    )
    if objects == 0:
        summary = "No objects in Quarantine"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"Objects": float(objects)},
            "details": "",
        },
    }