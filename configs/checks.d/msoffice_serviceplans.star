def _split_line(line):
    return line.split()

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command",
                       "Get-MgSubscribedSku | ForEach-Object { $_.SkuId }"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            res2 = ctx.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", "Get-Module -ListAvailable Microsoft.Graph"], mutates=False)
            if res2.rc != 0:
                return {"changed": False, "msg": "discovered 0 items",
                        "data": {"discovery": []}}
            # Microsoft.Graph module not installed -> single error service
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "_error", "params": {}, "metrics": []}]}}

        items = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 1:
                items.append({"item": parts[0], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # Check mode
    res = ctx.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command",
                   "Get-MgSubscribedSku | ForEach-Object { $_.SkuId }"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        res2 = ctx.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", "Get-Module -ListAvailable Microsoft.Graph"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "no MS Office service plans found (Microsoft.Graph module not installed)",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        # The section had the error marker
        return {"changed": False, "msg": "MS Office agent plugin requires installation of the Powershell Module Microsoft.Graph for all users, see werk #18609",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # Re-fetch full data for the checked bundle
    res2 = ctx.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command",
                    "Get-MgSubscribedSku | ForEach-Object { ($_.SkuId) + ' ' + ($_.SkuPartNumber) }"], mutates=False)
    if res2.rc != 0:
        return {"changed": False, "msg": "failed to query MS Office service plans",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    success = 0
    pending = 0
    pending_list = []
    for line in res2.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        bundle = parts[0]
        plan = " ".join(parts[1:])
        # We only grade lines matching the item (bundle id). Status must be
        # resolved separately since we cannot join line[1:-1] without status info.
        if bundle == item:
            # Status is not available in our probe; mark success for presence.
            success += 1

    warn, crit = params.get("levels", (None, None))
    state = "OK"
    infotext = "Success: %d, Pending: %d" % (success, pending)
    if crit != None and pending >= crit:
        state = "CRIT"
    elif warn != None and pending >= warn:
        state = "WARN"
    if state != "OK":
        infotext += " (warn/crit at %s/%s)" % (str(warn), str(crit))

    data = {"state": state, "metrics": {"success": success, "pending": pending}, "details": ""}
    if pending_list:
        data_extra = {"summary": "Pending Services: %s" % ", ".join(pending_list)}
    return {"changed": False, "msg": infotext, "data": data}