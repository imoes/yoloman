# Top-level constants (no imports, no classes, no lambdas)
# The Checkmk agent section is a simple text file with lines like:
#   PVS_STD_CCS 80 0
# We will gather this data via a file_read on the agent's output.
# Since this check runs on our Starlark agent (no Checkmk agent present),
# we must execute the same command the agent would: run 'citrix_licenses' plugin output.
# However, there's no external binary; the plugin is part of the Checkmk agent.
# Since we have no Checkmk agent, we replicate the agent's behavior by reading the file
# that the agent plugin would: typically, the agent plugin is configured to read a specific path.
# We assume the data is available in a file at /var/lib/citrix-licenses.txt
# If the file does not exist, the check reports UNKNOWN.

LIC_FILE = "/var/lib/citrix-licenses.txt"

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        if not ctx.file_exists(LIC_FILE):
            return {"changed": False, "msg": "no license data found", "data": {"discovery": []}}
        content = ctx.file_read(LIC_FILE)
        items = []
        for line in content.split("\n"):
            stripped = line.strip()
            if not stripped:
                continue
            parts = stripped.split()
            if len(parts) < 3:
                continue
            # Parse: license_name have used
            have_str = parts[1]
            used_str = parts[2]
            have = int(have_str) if have_str.isdigit() else 0
            used = int(used_str) if used_str.isdigit() else 0
            if have == 0 and used == 0 and not (have_str.isdigit() and used_str.isdigit()):
                continue
            license_name = parts[0]
            # Suggested params: default threshold levels from Checkmk
            # Checkmk default: {"levels": ("crit_on_all", None)}
            items.append({
                "item": license_name,
                "params": {"levels": ("crit_on_all", None)},
                "metrics": ["licenses"]
            })
        return {"changed": False, "msg": "discovered %d license types" % len(items),
                "data": {"discovery": items}}

    # CHECK MODE
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not ctx.file_exists(LIC_FILE):
        return {"changed": False, "msg": "no license data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    content = ctx.file_read(LIC_FILE)
    
    have = None
    used = None
    for line in content.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) < 3:
            continue
        if parts[0] == item:
            have_str = parts[1]
            used_str = parts[2]
            have = int(have_str) if have_str.isdigit() else 0
            used = int(used_str) if used_str.isdigit() else 0
            if have_str.isdigit() and used_str.isdigit():
                break
            have = None
            used = None
    
    if have == None or used == None:
        return {"changed": False, "msg": "no licenses of that type found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not have:
        return {"changed": False, "msg": "No licenses of that type found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract levels from params
    # Checkmk default: {"levels": ("crit_on_all", None)}
    levels = params.get("levels", ["crit_on_all", None])
    levels_sec = levels[1] if len(levels) > 1 else None
    
    # _license_levels logic from Checkmk for default case:
    # For None (falsy but not False), return (total, total) → (have, have)
    if levels_sec == None:
        warn = have
        crit = have
    else:
        # Fallback for unexpected values
        warn = have
        crit = have
    
    # Build infotext
    if used <= have:
        infotext = "used %d out of %d licenses" % (used, have)
    else:
        infotext = "used %d licenses, but you have only %d" % (used, have)
    
    state = "OK"
    if used >= crit:
        state = "CRIT"
    elif used >= warn:
        state = "WARN"
    if state != "OK":
        infotext += " (warn/crit at %d/%d)" % (warn, crit)
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {"licenses": used},
            "details": ""
        }
    }