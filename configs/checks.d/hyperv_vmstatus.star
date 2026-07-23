# Per Checkmk source: these two integration-service states map to OK.
# "Protocol_Mismatch" is safe per Microsoft by design.
OK_INT_STATES = ["Ok", "Protocol_Mismatch"]

def _is_positive_int(s):
    if len(s) == 0:
        return False
    for c in s:
        if c not in "0123456789":
            return False
    return int(s) > 0

def main(ctx, params):
    if params.get("_discover"):
        # Discover only when Hyper-V is present and has at least one VM.
        res = ctx.run(
            ["powershell.exe", "-NonInteractive", "-NoProfile", "-Command",
             "@(Get-VM -ErrorAction SilentlyContinue).Count"],
            mutates=False,
            ok_codes=[0, 1, 2, 127, 9009],
        )
        count = res.stdout.strip()
        if res.rc != 0 or not _is_positive_int(count):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Aggregate the worst IntegrationServicesState across all VMs.
    # Priority: Ok < Protocol_Mismatch < Degraded (anything else).
    ps_cmd = (
        "$vms = Get-VM -ErrorAction SilentlyContinue; " +
        "$state = 'Ok'; " +
        "foreach ($vm in $vms) { " +
        "$s = $vm.IntegrationServicesState; " +
        "if ($s -match 'Protocol') { if ($state -eq 'Ok') { $state = 'Protocol_Mismatch' } } " +
        "elseif ($s -ne 'Up to date' -and $s -ne $null) { $state = 'Degraded' } }; " +
        "$state"
    )
    res = ctx.run(
        ["powershell.exe", "-NonInteractive", "-NoProfile", "-Command", ps_cmd],
        mutates=False,
        ok_codes=[0, 1, 2, 127, 9009],
    )
    if res.rc != 0:
        detail = res.stderr.strip()
        return {
            "changed": False,
            "msg": "Hyper-V query failed: " + detail,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": detail},
        }
    int_state = res.stdout.strip()
    if not int_state:
        int_state = "Unknown"
    state = "OK" if int_state in OK_INT_STATES else "CRIT"
    return {
        "changed": False,
        "msg": "Integration Service State: " + int_state,
        "data": {"state": state, "metrics": {}, "details": ""},
    }