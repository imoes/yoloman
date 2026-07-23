# Constants for status mappings
DEFAULT_PARAMS = {
    "created": 2,
    "running": 0,
    "paused": 2,
    "restarting": 2,
    "removing": 2,
    "exited_with_zero": 0,
    "exited_with_non_zero": 2,
    "dead": 2,
}

def _format_exit_time(finished_at):
    if finished_at == "" or finished_at == None:
        return "unknown"
    # Parse ISO format date manually
    # Expected format: "2024-05-10T12:34:56.789Z" or similar
    parts = finished_at.split("T")
    if len(parts) < 2:
        return finished_at
    date_part = parts[0]
    time_part = parts[1]
    # Strip timezone info
    if "+" in time_part:
        time_part = time_part.split("+")[0]
    elif "Z" in time_part:
        time_part = time_part.rstrip("Z")
    
    # Format: YYYY-MM-DD HH:MM UTC
    return date_part + " " + time_part.split(".")[0].split("+")[0].split("Z")[0] + " UTC"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": DEFAULT_PARAMS, "metrics": []}
            ]}
        }
    
    # Check mode - probe podman inspect data
    res = ctx.run(["podman", "inspect", "--format=json", "containers"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to inspect containers",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Validate JSON output exists
    if res.stdout == "" or res.stdout == None:
        return {
            "changed": False,
            "msg": "no JSON output from podman inspect",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    containers = json.decode(res.stdout)
    
    if type(containers) != "list" or len(containers) == 0:
        return {
            "changed": False,
            "msg": "no containers found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get first container (Checkmk check assumes single container context)
    container = containers[0]
    state = container.get("State", {})
    
    status = state.get("Status", "unknown")
    exit_code = state.get("ExitCode", -1)
    finished_at = state.get("FinishedAt", "")
    name = container.get("Name", "").lstrip("/")
    pod = container.get("Pod", "")
    
    # Map status to internal keys
    if status == "exited":
        actual_status = "exited_with_zero" if exit_code == 0 else "exited_with_non_zero"
    else:
        actual_status = status
    
    # Build summary
    if status == "exited":
        exit_time = _format_exit_time(finished_at)
        summary = "Container %s exited at %s (code %d)" % (name, exit_time, exit_code)
    else:
        summary = actual_status.replace("_", " ").title()
    
    # Determine state based on params
    params_map = {}
    for k in DEFAULT_PARAMS.keys():
        params_map[k] = params.get(k, DEFAULT_PARAMS.get(k))
    
    # State mapping: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
    state_code = params_map.get(actual_status, 3)
    if state_code == 0:
        checkmk_state = "OK"
    elif state_code == 1:
        checkmk_state = "WARN"
    elif state_code == 2:
        checkmk_state = "CRIT"
    else:
        checkmk_state = "UNKNOWN"
    
    details = ""
    if pod:
        details = "Pod: " + pod.lstrip("/podman_") if pod.startswith("/podman_") else "Pod: " + pod
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": checkmk_state,
            "metrics": {},
            "details": details
        }
    }