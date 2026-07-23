def main(ctx, params):
    # Read agent section data for symantec_av_progstate
    # The agent provides this via JSON format with key "symantec_av_progstate"
    # containing [["Enabled"]] or [["Disabled"]]
    
    # Try to get the agent section data from the standard JSON format
    # Assuming the agent exposes section data via ctx.run() with a special command
    # or via a JSON structure. Since no explicit method is defined, we use
    # a standard approach: run the agent's section query command if available.
    
    # For this check, the original uses an agent section called "symantec_av_progstate"
    # which typically contains the status line like ["Enabled"]
    
    # In our environment, we assume the agent provides this via a JSON response
    # from a probe command. We'll use a simple approach: run a command to get the status.
    
    # For Linux systems with Symantec Endpoint Protection, the status can be obtained via:
    # /opt/Symantec/symantec-av/sep --status  or similar
    
    # Let's try the most common path first: direct status check
    
    res = ctx.run(["/opt/Symantec/symantec-av/sep", "status"], mutates=False)
    if res.rc == 0:
        # Parse output: look for "Program Status: Enabled"
        status = "Unknown"
        for line in res.stdout.splitlines():
            line_stripped = line.strip()
            if line_stripped.lower().startswith("program status:"):
                parts = line_stripped.split(":", 1)
                if len(parts) >= 2:
                    status = parts[1].strip()
                break
    else:
        # Fall back to reading from agent section file
        status = "Unknown"
        if ctx.file_exists("/var/lib/check-mk-agent/agent/symantec_av_progstate"):
            content = ctx.file_read("/var/lib/check-mk-agent/agent/symantec_av_progstate")
            lines = content.splitlines()
            if len(lines) > 0:
                first_line = lines[0].strip()
                # Remove quotes if present
                if (first_line.startswith('"') and first_line.endswith('"')) or (first_line.startswith("'") and first_line.endswith("'")):
                    first_line = first_line[1:-1]
                status = first_line
    
    # Apply check logic
    if status.lower() != "enabled":
        return {
            "changed": False,
            "msg": "Program Status is %s" % status,
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }
    
    return {
        "changed": False,
        "msg": "Program enabled",
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }