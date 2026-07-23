# ===== check module: datadog_logs =====
# Read-only Starlark translation of the Checkmk datadog_logs check.
# This check reports the number of logs forwarded to the Event Console
# by the Datadog special agent. It always reports OK.

def main(ctx, params):
    # Attempt to read the logs count from a common Datadog agent file
    # If the file doesn't exist, we assume 0 logs forwarded
    log_count_file = "/var/lib/datadog/logs_count"
    n_logs = 0  # default if file doesn't exist or is unreadable
    
    if ctx.file_exists(log_count_file):
        # ctx.file_read returns a string; we parse it safely
        content = ctx.file_read(log_count_file)
        stripped = content.strip()
        # Guard: only convert if all digits (or negative digits)
        if len(stripped) > 0:
            is_valid = True
            if stripped.startswith("-"):
                is_valid = stripped[1:].isdigit() and len(stripped) > 1
            else:
                is_valid = stripped.isdigit()
            if is_valid:
                n_logs = int(stripped)
    
    # For discovery: always discover one service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []}
            ]},
        }
    
    # Check mode: always OK, report the count
    # Format the summary message
    log_word = "log" if n_logs == 1 else "logs"
    summary = "Forwarded %d %s to the Event Console" % (n_logs, log_word)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }
