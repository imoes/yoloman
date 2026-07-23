# ===== check plugin: cmk/plugins/solaris/agent_based/solaris_fmadm =====

def parse_solaris_fmadm_output(stdout):
    if stdout == "":
        return {}
    
    lines = stdout.splitlines()
    if len(lines) < 4:
        return {}
    
    # Parse event line (line index 3 in original logic)
    event_line = ":".join(lines[3]) if isinstance(lines[3], list) else lines[3]
    event_parts = []
    for part in event_line.split():
        if part.strip():
            event_parts.append(part.strip())
    
    if len(event_parts) < 4:
        return {}
    
    event_time = " ".join(event_parts[:-3])
    event_id = event_parts[-3]
    msg_id = event_parts[-2]
    severity = event_parts[-1].lower()
    
    # Parse problems (lines after header)
    problems = []
    for line in lines[4:]:
        stripped_line = line.strip()
        if stripped_line.startswith("Problem class") or stripped_line.startswith("Fault class"):
            # Extract the value after the colon
            colon_idx = stripped_line.find(":")
            if colon_idx != -1:
                problem_value = stripped_line[colon_idx+1:].strip()
                if problem_value:
                    problems.append(problem_value)
    
    return {
        "event": {
            "time": event_time,
            "id": event_id,
            "msg": msg_id,
            "severity": severity,
        },
        "problems": problems,
    }


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: always discover a single service
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }
    
    # Check mode
    res = ctx.run(["fmadm", "faulty"], mutates=False)
    section = parse_solaris_fmadm_output(res.stdout)
    
    if not section:
        return {
            "changed": False,
            "msg": "No faults detected",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    
    event = section["event"]
    severity = event["severity"]
    
    # Map severity to state and readable name
    state_map = {
        "minor": ("WARN", "minor"),
        "major": ("CRIT", "major"),
        "critical": ("CRIT", "critical"),
    }
    
    state, state_readable = state_map.get(severity, ("UNKNOWN", "unknown"))
    
    # Build summary
    msg = "Severity: %s (%s)" % (state_readable, event["time"])
    problems = section["problems"]
    
    # Add problems to details if any exist
    details = ""
    if problems:
        details = "Problems: %s" % ", ".join(problems)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": details
        }
    }
