def main(ctx, params):
    # Read the heartbeat_rscstatus section from the agent (simulated via /proc/cluster/status or similar)
    # Checkmk agent plugins typically read /proc/cluster/status or run a command like 'crm_mon -1'
    # For this specific plugin, the source parses <<<heartbeat_rscstatus>>> which is just one line.
    # On a system without Checkmk agent, we simulate the same by reading a standard location
    # or running a command. Heartbeat/Pacemaker states are usually exposed via crm_mon or procfs.
    
    # The agent plugin parses the raw <<<heartbeat_rscstatus>>> line. We simulate this by running
    # 'crm_mon -1' (if available) or fallback to reading /proc/cluster/status.
    # Since we must be portable, we try 'crm_mon -1 -r' to get resource status and parse the first line.
    
    res = ctx.run(["crm_mon", "-1", "-r"], mutates=False)
    output = res.stdout.strip()
    # If crm_mon fails, fallback to checking /proc/cluster/status or similar
    if res.rc != 0 or not output:
        # Check for /proc/cluster/status as fallback
        if ctx.file_exists("/proc/cluster/status"):
            content = ctx.file_read("/proc/cluster/status")
            # Parse first line of /proc/cluster/status
            lines = content.split("\n")
            if lines:
                output = lines[0].strip()
        else:
            # If no fallback file exists, try alternative: look at Pacemaker's status via pcs
            res2 = ctx.run(["pcs", "status", "resources"], mutates=False)
            if res2.rc == 0:
                # Try to find a line like "Resource Group: ..." or simple status
                lines = res2.stdout.split("\n")
                for line in lines:
                    stripped = line.strip()
                    if stripped in ["local", "foreign", "all", "none"]:
                        output = stripped
                        break
            else:
                # Final fallback: check if crm_mon output is available via different name
                # If nothing works, assume we have no data
                return {
                    "changed": False,
                    "msg": "Heartbeat resource status data unavailable",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
    
    # Parse the section as per original: first non-empty line
    section = None
    if output:
        lines = output.split("\n")
        for line in lines:
            stripped = line.strip()
            if stripped in ["local", "foreign", "all", "none", ""]:
                section = stripped
                break
    
    # Discovery mode: enumerate the service with discovered_state
    if params.get("_discover"):
        if section == None:
            return {
                "changed": False,
                "msg": "no heartbeat_rscstatus data found",
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "discovered Heartbeat Ressource Status service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"discovered_state": section},
                        "metrics": []
                    }
                ]
            }
        }
    
    # Check mode: compare with expected state
    item = params.get("item", "")
    if item != "":
        # This check only supports item "", per Checkmk's original
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if section == None:
        return {
            "changed": False,
            "msg": "no heartbeat_rscstatus data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get expected state from params
    expected_state = params.get("discovered_state")
    if params.get("expected_state") != None:
        expected_state = params.get("expected_state")
    
    if expected_state == None:
        # If no expected state given, default to using the discovered state as expected
        expected_state = section
    
    if expected_state == section:
        return {
            "changed": False,
            "msg": "Current state: %s" % section,
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    else:
        return {
            "changed": False,
            "msg": "Current state: %s (Expected: %s)" % (section, expected_state),
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }