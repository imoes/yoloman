# Translated Checkmk check: checkmk.hyperv_vmstatus
# Monitors HyperV VM Integration Services status (read-only)

def main(ctx, params):
    # Probe for real Hyper-V presence first
    ps_probe = ctx.run(["powershell.exe", "-NoProfile", "-Command", "Get-Module -ListAvailable -Name Hyper-V"], mutates=False)
    if ps_probe.rc != 0:
        # Hyper-V not installed/present
        if ps_probe.skipped:
            return {"changed": False, "msg": "would check HyperV status", "data": {"state": "UNKNOWN", "metrics": {}, "details": "check_mode skipped"}}
        return {"changed": False, "msg": "Hyper-V not available on this host", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Hyper-V module not found"}}

    if params.get("_discover"):
        # Discovery: single service when Hyper-V is present
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    # Check mode: gather VM integration service status
    # Query Hyper-V VM integration services via PowerShell
    ps_query = ctx.run(["powershell.exe", "-NoProfile", "-Command",
        "Get-VM | ForEach-Object { Write-Host ($_.Name + '|' + ($_.IntegrationServices | ForEach-Object { $_.Enabled + ':' + $_.PrimaryStatus }) -join ',') }"],
        mutates=False)

    if ps_query.rc != 0:
        return {"changed": False, "msg": "failed to query Hyper-V VMs", "data": {"state": "UNKNOWN", "metrics": {}, "details": "PowerShell command failed: " + ps_query.stderr}}

    # Determine overall Integration_Services state
    integration_state = None
    has_issues = False
    lines = ps_query.stdout.splitlines()
    for line in lines:
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|", 1)
        vm_name = parts[0]
        services_part = parts[1] if len(parts) > 1 else ""
        # Parse service states: format "True:OK,False:Error"
        for svc in services_part.split(","):
            svc = svc.strip()
            if ":" in svc:
                status_part = svc.split(":", 1)[1].strip()
                if status_part == "OK":
                    continue
                elif status_part == "Degraded":
                    integration_state = "Degraded" if integration_state == None else integration_state
                elif status_part == "Error" or status_part == "Error,Operational":
                    has_issues = True
                    integration_state = "Error"

    # Map to Checkmk expected states
    if integration_state == None and not has_issues:
        int_state = "Ok"
    elif has_issues:
        int_state = "Error"
    elif integration_state == "Degraded":
        int_state = "Degraded"
    else:
        int_state = integration_state if integration_state != None else "Ok"

    # Per Microsoft guidance: 'Protocol_Mismatch' is OK
    state = "OK" if int_state in ("Ok", "Protocol_Mismatch") else "CRIT"
    return {"changed": False, "msg": "Integration Service State: " + str(int_state), "data": {"state": state, "metrics": {}, "details": ps_query.stdout}}