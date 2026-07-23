# Starlark module for Checkmk check: checkmk.msexch_owa
# Read-only check module - gathers Exchange OWA WMI metrics

def main(ctx, params):
    # Discovery mode: enumerate items from WMI table
    if params.get("_discover"):
        res = ctx.run(["wmic", "path", "Win32_PerfRawData_MicrosoftExchangeOWA_MicrosoftExchangeOWA", "get", "RequestsPersec,CurrentUniqueUsers,Name", "/format:csv"], mutates=False)
        out = []
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": out}}
        header = lines[0].lower().split(",")
        if not "name" in header or not "requestspersec" in header or not "currentuniqueusers" in header:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": out}}
        name_idx = header.index("name")
        requests_idx = header.index("requestspersec")
        users_idx = header.index("currentuniqueusers")
        for line in lines[1:]:
            fields = line.split(",")
            if len(fields) < max(name_idx, requests_idx, users_idx) + 1:
                continue
            name = fields[name_idx].strip()
            if name == "" or name == "_Total":
                out.append({"item": "", "params": {},
                            "metrics": ["requests_per_sec", "current_users"]})
                break
        return {"changed": False, "msg": "discovered %d item(s)" % len(out),
                "data": {"discovery": out}}

    # Check mode: verify one item (item is always "" for this check)
    res = ctx.run(["wmic", "path", "Win32_PerfRawData_MicrosoftExchangeOWA_MicrosoftExchangeOWA",
                   "get", "RequestsPersec,CurrentUniqueUsers,Name", "/format:csv"], mutates=False)
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "Exchange OWA data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    header = lines[0].lower().split(",")
    if not "name" in header or not "requestspersec" in header or not "currentuniqueusers" in header:
        return {"changed": False, "msg": "Exchange OWA data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    requests_idx = header.index("requestspersec")
    users_idx = header.index("currentuniqueusers")
    name_idx = header.index("name")

    requests = 0
    users = 0
    found_total = False
    for line in lines[1:]:
        fields = line.split(",")
        if len(fields) < max(requests_idx, users_idx, name_idx) + 1:
            continue
        name = fields[name_idx].strip()
        if name == "" or name == "_Total":
            if fields[requests_idx].isdigit():
                requests = int(fields[requests_idx])
            if fields[users_idx].isdigit():
                users = int(fields[users_idx])
            found_total = True
            break

    if not found_total:
        return {"changed": False, "msg": "Exchange OWA data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {
        "requests_per_sec": requests,
        "current_users": users,
    }

    return {
        "changed": False,
        "msg": "Requests/sec: %d, Unique users: %d" % (requests, users),
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": "",
        },
    }
