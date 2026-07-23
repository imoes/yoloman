CONSTANTS_MAP = {
    "maintenancemode": {
        "False": 0,
        "True": 1,
    },
    "powerstate": {
        "Unmanaged": 1,
        "Unknown": 1,
        "Unavailable": 2,
        "Off": 2,
        "On": 0,
        "Suspended": 2,
        "TurningOn": 1,
        "TurningOff": 1,
    },
    "vmtoolsstate": {
        "NotPresent": 2,
        "Unknown": 3,
        "NotStarted": 1,
        "Running": 0,
    },
    "faultstate": {
        "None": 0,
        "FailedToStart": 2,
        "StuckOnBoot": 2,
        "Unregistered": 2,
        "MaxCapacity": 1,
    },
    "registrationstate": {
        "Unregistered": 2,
        "Initializing": 1,
        "Registered": 0,
        "AgentError": 2,
    },
}

STATE_INT_TO_STR = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

INSTANCE_FIELDS = [
    "FaultState",
    "MaintenanceMode",
    "PowerState",
    "RegistrationState",
    "VMToolsState",
]

PS_CMD = (
    "Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction SilentlyContinue; " +
    "$m = Get-BrokerMachine -MachineName ($env:USERDOMAIN + '\\' + $env:COMPUTERNAME) " +
    "-ErrorAction SilentlyContinue; " +
    "if ($m) { " +
    "Write-Output ('RegistrationState ' + $m.RegistrationState); " +
    "Write-Output ('PowerState ' + $m.PowerState); " +
    "Write-Output ('MaintenanceMode ' + $m.InMaintenanceMode); " +
    "Write-Output ('VMToolsState ' + $m.VMToolsState); " +
    "Write-Output ('FaultState ' + $m.FaultState); " +
    "if ($m.ControllerDNSName) { Write-Output ('Controller ' + $m.ControllerDNSName) }; " +
    "if ($m.HostingServerName) { Write-Output ('HostingServer ' + $m.HostingServerName) } " +
    "}"
)


def _parse_section(output):
    section = {"instance": {}}
    for raw in output.splitlines():
        line = raw.strip()
        if not line:
            continue
        idx = line.find(" ")
        if idx < 0:
            continue
        key = line[:idx]
        val = line[idx + 1:]
        if key == "Controller":
            section["controller"] = val
        elif key == "HostingServer":
            section["hosting_server"] = val
        elif key in INSTANCE_FIELDS:
            section["instance"][key] = val
    return section


def main(ctx, params):
    res = ctx.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", PS_CMD],
        mutates=False,
        ok_codes=[0, 1],
    )

    if params.get("_discover"):
        if not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        section = _parse_section(res.stdout)
        if not section["instance"]:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Citrix state data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse_section(res.stdout)
    instance = section["instance"]

    if not instance:
        return {
            "changed": False,
            "msg": "no Citrix instance state found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    worst = 0
    summaries = []

    for state_type in sorted(instance.keys()):
        state_val = instance[state_type]
        key = state_type.lower()
        monitoring_map = params.get(key) or CONSTANTS_MAP.get(key)
        if monitoring_map == None:
            continue
        num = monitoring_map.get(state_val, 3)
        if num > worst:
            worst = num
        summaries.append("%s %s" % (state_type, state_val))

    state_str = STATE_INT_TO_STR.get(worst, "UNKNOWN")
    msg = ", ".join(summaries) if summaries else "no state data"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state_str, "metrics": {}, "details": ""},
    }