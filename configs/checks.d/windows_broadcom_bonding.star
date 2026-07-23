# ===== Starlark check module: windows_broadcom_bonding =====
# Translate Checkmk check for Windows Broadcom network bonding status
# Reads agent section <<<windows_broadcom_bonding>>> by executing a PowerShell command
# that mimics the original Windows agent output format.

def _get_broadcom_bonding_lines(ctx):
    """Return raw output lines from the Broadcom bonding agent section."""
    # Use PowerShell to query WMI for network adapters with Broadcom-like names
    # and their RedundancyStatus (Win32_NetworkAdapter with StatusInfo)
    # Fallback to simple PowerShell script that queriesMSNdis_*. RedundancyStatus
    # but in practice the agent section expects specific output format.
    # Since Checkmk agent outputs <<<windows_broadcom_bonding>>>, we simulate the same.
    # In practice, the Windows agent plugin runs a script like:
    #   Get-WmiObject -Class MSNdis_ExtendedNetAdapterInfo | Select-Object Name, Status
    # But for compatibility, we match exact Checkmk agent output format.
    # Use PowerShell to extract the required info with exact Caption + RedundancyStatus
    res = ctx.run([
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-Command",
        "$bonds = Get-WmiObject -Class Win32_NetworkAdapter -Filter \"AdapterTypeId = 0\" | " +
        "Where-Object { $_.Name -match 'Broadcom|Bond' }; " +
        "if ($bonds) { $bonds | ForEach-Object { Write-Host ('{0} {1}' -f $_.Caption, $_.StatusInfo) } }"
    ], mutates=False)
    if res.rc != 0:
        # Return empty if command fails (e.g., no WMI data) — check will report UNKNOWN
        return []
    return res.stdout.splitlines()

def _parse_bonding_output(lines):
    """Parse raw bonding lines into list of [caption, status] pairs."""
    result = []
    for line in lines:
        parts = line.strip().split()
        if len(parts) >= 2:
            # Join all but last part as caption (may have spaces), last is status
            caption = " ".join(parts[:-1])
            status_str = parts[-1]
            if status_str.isdigit():
                result.append([caption, status_str])
    return result

def main(ctx, params):
    # Discovery mode: enumerate all bonding interfaces
    if params.get("_discover"):
        lines = _get_broadcom_bonding_lines(ctx)
        section = _parse_bonding_output(lines)
        items = []
        for entry in section[1:] if len(section) > 0 else []:
            # Use Caption as item (join of all but last column)
            item = " ".join(entry[:-1])
            items.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d bonding interfaces" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: examine one specific item
    item = params.get("item", "")
    lines = _get_broadcom_bonding_lines(ctx)
    section = _parse_bonding_output(lines)
    
    # Find matching bond
    found = False
    for entry in section:
        caption = " ".join(entry[:-1])
        if caption == item:
            found = True
            status_str = entry[-1]
            status = int(status_str) if status_str.isdigit() else -1
            if status == 5:
                return {
                    "changed": False,
                    "msg": "Bond not working",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}
                }
            elif status == 4:
                return {
                    "changed": False,
                    "msg": "Bond partly working",
                    "data": {"state": "WARN", "metrics": {}, "details": ""}
                }
            elif status == 2:
                return {
                    "changed": False,
                    "msg": "Bond fully working",
                    "data": {"state": "OK", "metrics": {}, "details": ""}
                }
            else:
                return {
                    "changed": False,
                    "msg": "Bond status cannot be recognized",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
    
    if not found:
        return {
            "changed": False,
            "msg": "Bond %s not found in agent output" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }