# Checkmk check → read-only Starlark check module: heartbeat_rscstatus

def main(ctx, params):
    if params.get("_discover"):
        section = _get_rscstatus(ctx)
        if section == None:
            return {"changed": False, "msg": "no heartbeat rscstatus found",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"discovered_state": section},
                     "metrics": []}
                ]}}

    item = params.get("item", "")
    section = _get_rscstatus(ctx)
    if section == None:
        return {"changed": False, "msg": "no heartbeat rscstatus found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    expected_state = params.get("discovered_state")
    if params.get("expected_state") != None:
        expected_state = params.get("expected_state")
    if expected_state == None:
        expected_state = section

    if expected_state == section:
        state = "OK"
        summary = "Current state: " + str(section)
    else:
        state = "CRIT"
        summary = "Current state: " + str(section) + " (Expected: " + str(expected_state) + ")"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}


def _get_rscstatus(ctx):
    for path in ["/proc/drbd", "/var/lib/heartbeat/crm/STATUS"]:
        if ctx.file_exists(path):
            content = ctx.file_read(path)
            for line in content.splitlines():
                s = line.strip()
                if s in ["local", "foreign", "all", "none"]:
                    return s
    return None