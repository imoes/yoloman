def _parse_section(output):
    section = {}
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" ", 1)
        key = parts[0]
        value = parts[1].strip() if len(parts) > 1 else ""
        if key == "Controller":
            section["controller"] = value
        elif key == "HostingServer":
            section["hosting_server"] = value
    return section

_PS_CMD = (
    "$ErrorActionPreference='SilentlyContinue';" +
    "$v=Get-WmiObject -Namespace 'root\\citrix' -Class 'Citrix_VirtualMachineData';" +
    "if($v){" +
    "Write-Output('Controller '+$v.ControllerDNSName);" +
    "Write-Output('HostingServer '+$v.HostingServerName)" +
    "}"
)

def main(ctx, params):
    res = ctx.run(
        ["powershell", "-NonInteractive", "-NoProfile", "-Command", _PS_CMD],
        mutates=False,
    )

    if params.get("_discover"):
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        section = _parse_section(res.stdout)
        if "controller" not in section:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Citrix VDA data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr.strip()},
        }

    section = _parse_section(res.stdout)
    if "controller" not in section:
        return {
            "changed": False,
            "msg": "no controller info in VDA output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    controller = section["controller"]
    msg = controller if controller else "Machine powered off"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }