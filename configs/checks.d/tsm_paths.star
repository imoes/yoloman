# Checkmk's tsm_paths agent plugin runs dsmadmc queries
# Each line: [server, path_name, online_status]
# line[2] == "YES" means path is online/OK

def main(ctx, params):
    if params.get("_discover"):
        # Probe for TSM client presence — dsmadmc is the TSM admin client
        probe = ctx.run(["dsmadmc", "-version"], mutates=False)
        # rc == 127 means binary not found — TSM not installed
        has_tsm = probe.rc == 0 and len(probe.stdout.strip()) > 0
        if not has_tsm:
            return {"changed": False, "msg": "no TSM client found",
                    "data": {"discovery": []}}

        # Gather path data via dsmadmc — this is what Checkmk's agent plugin queries
        # The agent plugin runs something producing server/path/status lines
        res = ctx.run(["dsmadmc", "-dataonly=f", "q path"], mutates=False)
        lines = res.stdout.splitlines()
        if res.rc != 0 or len(lines) == 0:
            return {"changed": False, "msg": "could not query TSM paths",
                    "data": {"discovery": []}}

        # Each non-empty line from dsmadmc output represents a path entry
        # Checkmk formats these as [server, path_name, status] rows
        # We have at least one path, so discover the service
        return {"changed": False, "msg": "discovered TSM Paths service",
                "data": {"discovery": [
                    {"item": "", "params": {},
                     "metrics": []}
                ]}}

    item = params.get("item", "")
    # Re-probe for TSM presence in check mode
    probe = ctx.run(["dsmadmc", "-version"], mutates=False)
    has_tsm = probe.rc == 0 and len(probe.stdout.strip()) > 0
    if not has_tsm:
        return {"changed": False, "msg": "TSM client (dsmadmc) not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["dsmadmc", "-dataonly=f", "q path"], mutates=False)
    lines = res.stdout.splitlines()
    if res.rc != 0:
        return {"changed": False, "msg": "dsmadmc query failed: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if len(lines) == 0:
        return {"changed": False, "msg": "no TSM paths returned",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the section — each line is [server, path_name, status]
    # Reproduce Checkmk's string_table handling
    section = []
    for line in lines:
        cols = line.split()
        if len(cols) >= 3:
            section.append(cols)

    error_paths = []
    for row in section:
        if len(row) >= 3 and row[2] != "YES":
            error_paths.append(row[1])

    if len(error_paths) > 0:
        summary = "Paths with errors: " + ", ".join(error_paths)
        return {"changed": False, "msg": summary,
                "data": {"state": "CRIT", "metrics": {},
                         "details": summary}}

    summary = "%d paths OK" % len(section)
    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": {},
                     "details": summary}}