_PS_CMD = (
    "if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) {" +
    " $skus = Get-MgSubscribedSku;" +
    " foreach ($sku in $skus) {" +
    "  foreach ($p in $sku.ServicePlans) {" +
    "   Write-Output ('mggraph:' + $sku.SkuPartNumber + ' ' + $p.ServicePlanName + ' ' + $p.ProvisioningStatus)" +
    "  }" +
    " }" +
    "} else { Write-Output 'Microsoft.Graph module is not installed' }"
)

_GRAPH_ERR = "Microsoft.Graph module is not installed"

def _collect_lines(ctx):
    res = ctx.run(
        ["powershell.exe", "-NonInteractive", "-NoProfile", "-Command", _PS_CMD],
        mutates=False,
        ok_codes=[0, 1],
    )
    lines = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line:
            parts = line.split()
            if len(parts) >= 1:
                lines.append(parts)
    return lines

def _has_error(lines):
    for parts in lines:
        if _GRAPH_ERR in " ".join(parts):
            return True
    return False

def main(ctx, params):
    lines = _collect_lines(ctx)
    graph_missing = _has_error(lines)

    if params.get("_discover"):
        if graph_missing:
            return {
                "changed": False,
                "msg": "discovered 1 items",
                "data": {"discovery": [
                    {"item": "_error", "params": {}, "metrics": []},
                ]},
            }
        seen = {}
        items = []
        for parts in lines:
            if len(parts) >= 1:
                bundle = parts[0]
                if bundle not in seen:
                    seen[bundle] = True
                    items.append({
                        "item": bundle,
                        "params": {"levels": [None, None]},
                        "metrics": ["success", "pending"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    # check mode
    item = params.get("item", "")

    if graph_missing:
        return {
            "changed": False,
            "msg": "MS Office agent plugin requires installation of the Powershell Module Microsoft.Graph for all users, see werk #18609",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", [None, None])
    warn = levels[0]
    crit = levels[1]

    success = 0
    pending = 0
    pending_list = []

    for parts in lines:
        if len(parts) < 2:
            continue
        bundle = parts[0]
        if bundle != item:
            continue
        status = parts[-1]
        plan = " ".join(parts[1:-1])
        if status == "Success":
            success += 1
        elif status == "PendingActivation":
            pending += 1
            pending_list.append(plan)

    state = "OK"
    msg = "Success: %d, Pending: %d" % (success, pending)
    if crit != None and pending >= crit:
        state = "CRIT"
    elif warn != None and pending >= warn:
        state = "WARN"
    if state != "OK":
        msg = msg + " (warn/crit at %s/%s)" % (str(warn), str(crit))

    details = ""
    if pending_list:
        details = "Pending Services: %s" % ", ".join(pending_list)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"success": success, "pending": pending},
            "details": details,
        },
    }