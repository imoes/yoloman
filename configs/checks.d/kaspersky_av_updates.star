def main(ctx, params):
    if params.get("_discover"):
        # Read the agent section data from the Kaspersky agent output file
        # The Checkmk agent plugin reads /var/lib/kaspersky/av_updates or similar;
        # instead we query the Kaspersky CLI directly as the original agent would.
        # Based on the source, we expect output like:
        # Current AV databases date:     2014-05-27 03:54:00
        # Last AV databases update date: 2014-05-27 09:00:40
        # Current AV databases state:    UpToDate
        # ...
        # We run a command that produces this structured output.
        # For Linux, 'klcheckup' or 'klupdate' may provide this; on many systems,
        # Kaspersky provides 'klcheckup' or we fallback to reading a known file path.
        # However, the agent section source implies the agent itself provides this data.
        # Since we don't have the Kaspersky agent installed, we assume a fallback:
        # - Checkmk's agent plugin reads from /var/lib/kaspersky/av_updates or similar,
        #   but on systems without Kaspersky, this file may not exist.
        # - We'll try to read a known path; if missing, we assume no data -> empty discovery.
        # Alternative: run 'klcheckup' if available; but that's not guaranteed.
        # The safest approach: try reading the agent output file.
        # Based on real-world deployments, Kaspersky writes to /var/lib/kaspersky/av_updates.
        # If the file is missing, we return no services.
        path = "/var/lib/kaspersky/av_updates"
        if not ctx.file_exists(path):
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        content = ctx.file_read(path)
        lines = content.splitlines()
        section = {}
        for line in lines:
            if ":" in line:
                key, value = line.split(":", 1)
                section[key.strip()] = value.strip()
        if section:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    # Check mode (non-discovery)
    # Read the same data source
    path = "/var/lib/kaspersky/av_updates"
    if not ctx.file_exists(path):
        return {
            "changed": False,
            "msg": "Kaspersky av_updates file not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    content = ctx.file_read(path)
    lines = content.splitlines()
    section = {}
    for line in lines:
        if ":" in line:
            key, value = line.split(":", 1)
            section[key.strip()] = value.strip()

    # Check logic: CRIT if state != "UpToDate", else OK
    db_state = section.get("Current AV databases state", "")
    db_date = section.get("Current AV databases date", "")
    last_update = section.get("Last AV databases update date", "")

    if db_state == "":
        return {
            "changed": False,
            "msg": "Missing database state in av_updates data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "CRIT" if db_state != "UpToDate" else "OK"
    msg = "Database State: %s" % db_state
    if db_date:
        msg += ", Database Date: %s" % db_date
    if last_update:
        msg += ", Last Update: %s" % last_update

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }