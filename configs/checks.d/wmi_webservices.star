def main(ctx, params):
    # Discovery mode: enumerate Web Service instances
    if params.get("_discover"):
        # Query WMI for WebService instances using PowerShell (standard on Windows)
        # We fetch CurrentConnections for each instance, excluding _Total
        cmd = "Get-WmiObject -Class Win32_PerfRawData_W3SVC_WebService | Select-Object -Property Name,CurrentConnections | Format-Table -HideTableHeaders -Wrap"
        res = ctx.run(["powershell", "-Command", cmd], mutates=False)
        if res.rc != 0:
            fail("failed to query WMI: " + res.stderr)

        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            name = parts[0].strip('"')
            # Skip _Total and empty names
            if name == "_Total" or name == "":
                continue
            items.append({
                "item": name,
                "params": {},
                "metrics": ["connections"]
            })

        return {
            "changed": False,
            "msg": "discovered %d web services" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: verify single item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Query WMI for the specific instance
    cmd = ("Get-WmiObject -Class Win32_PerfRawData_W3SVC_WebService -Filter \"Name='%s'\" | " +
           "Select-Object -ExpandProperty CurrentConnections") % item
    res = ctx.run(["powershell", "-Command", cmd], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query WMI for " + item + ": " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    stdout = res.stdout.strip()
    if not stdout.isdigit():
        return {
            "changed": False,
            "msg": "invalid data for " + item + ": " + stdout,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value = int(stdout)

    # Determine state based on thresholds (no default levels in source, use OK)
    state = "OK"
    msg = item + ": " + str(value) + " connections"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"connections": value},
            "details": ""
        }
    }