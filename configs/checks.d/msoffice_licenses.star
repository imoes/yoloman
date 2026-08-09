PS_SCRIPT = "Get-MgSubscribedSku | ForEach-Object { 'mggraph:' + $_.SkuPartNumber + ' ' + $_.PrepaidUnits.Enabled + ' ' + $_.PrepaidUnits.Warning + ' ' + $_.ConsumedUnits }"

def _parse_licenses(stdout):
    licenses = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if "Microsoft.Graph module is not installed" in line:
            return {"_error": "MS Office agent plugin requires installation of the Powershell Module Microsoft.Graph for all users, see werk #18609"}
        parts = line.split()
        if len(parts) != 4:
            continue
        if not parts[1].isdigit() or not parts[2].isdigit() or not parts[3].isdigit():
            continue
        name = parts[0]
        if name not in licenses:
            licenses[name] = {
                "active": int(parts[1]),
                "warning_units": int(parts[2]),
                "consumed": int(parts[3]),
            }
    return licenses

def main(ctx, params):
    res = ctx.run(
        ["powershell", "-NonInteractive", "-Command", PS_SCRIPT],
        mutates=False,
        ok_codes=[0, 1],
    )
    licenses = _parse_licenses(res.stdout)

    if params.get("_discover"):
        items = []
        for name in licenses:
            if name == "_error":
                continue
            items.append({
                "item": name,
                "params": {"usage": [80.0, 90.0]},
                "metrics": ["licenses", "licenses_total", "license_percentage"],
            })
        return {
            "changed": False,
            "msg": "discovered %d license types" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    if "_error" in licenses:
        return {
            "changed": False,
            "msg": licenses["_error"],
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    if item not in licenses:
        return {
            "changed": False,
            "msg": "license not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    item_data = licenses[item]
    lcs_active = item_data["active"]
    lcs_consumed = item_data["consumed"]
    lcs_warning_units = item_data["warning_units"]

    if lcs_active == 0:
        return {
            "changed": False,
            "msg": "No active licenses",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    usage_param = params.get("usage", [80.0, 90.0])
    warn = usage_param[0]
    crit = usage_param[1]

    usage = lcs_consumed * 100.0 / lcs_active
    metrics = {
        "licenses": lcs_consumed,
        "licenses_total": lcs_active,
        "license_percentage": usage,
    }

    state = "OK"
    if type(warn) == "float":
        if usage >= crit:
            state = "CRIT"
        elif usage >= warn:
            state = "WARN"
    else:
        if lcs_consumed >= crit:
            state = "CRIT"
        elif lcs_consumed >= warn:
            state = "WARN"

    msg_parts = [
        "Consumed licenses: %d" % lcs_consumed,
        "Active licenses: %d" % lcs_active,
        "Usage: %f%%" % usage,
    ]
    if lcs_warning_units:
        msg_parts.append("Warning units: %d" % lcs_warning_units)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }