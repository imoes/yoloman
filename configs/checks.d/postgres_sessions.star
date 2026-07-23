# Top-level helpers for parsing postgres_sessions agent output
def _parse_postgres_sessions(string_table):
    parsed = {}
    instance_name = ""
    for line in string_table:
        if len(line) < 1:
            continue
        if line[0].startswith("[[[") and line[0].endswith("]]]"):
            instance_name = line[0][3:-3].upper()
            continue
        instance = parsed.setdefault(
            instance_name,
            {
                "total": 0,
                "running": 0,
            },
        )
        if len(line) < 2:
            continue
        if line[0].startswith("t"):
            instance["total"] = int(line[1])
        elif line[0].startswith("f"):
            instance["running"] = int(line[1])
    return parsed

def _split_lines(content):
    lines = content.splitlines()
    if len(lines) > 0 and lines[len(lines) - 1] == "":
        lines = lines[:len(lines) - 1]
    return lines

def _build_string_table(content):
    table = []
    for line in _split_lines(content):
        fields = line.split()
        if len(fields) >= 1:
            table.append(fields)
    return table

def main(ctx, params):
    if params.get("_discover"):
        # First check if psql is available
        psql_res = ctx.run(["which", "psql"], mutates=False)
        if psql_res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items (psql not found)",
                "data": {"discovery": []},
            }

        # Try to get active sessions count
        active_res = ctx.run([
            "psql",
            "-t", "-A",
            "-c", "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"
        ], mutates=False)

        # Fallback if first query fails
        if active_res.rc != 0:
            active_res = ctx.run([
                "psql",
                "-t", "-A",
                "-c", "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle';"
            ], mutates=False)

        # Get total sessions count
        total_res = ctx.run([
            "psql",
            "-t", "-A",
            "-c", "SELECT count(*) FROM pg_stat_activity;"
        ], mutates=False)

        # Parse total count with guard instead of try/except
        total_count = 0
        if total_res.rc == 0 and total_res.stdout != None and len(total_res.stdout.strip()) > 0:
            total_str = total_res.stdout.strip()
            total_count = int(total_str) if total_str.isdigit() else 0

        # Parse active count with guard instead of try/except
        active_count = 0
        if active_res.rc == 0 and active_res.stdout != None and len(active_res.stdout.strip()) > 0:
            active_str = active_res.stdout.strip()
            active_count = int(active_str) if active_str.isdigit() else 0

        # Check if we have any sessions to discover
        if total_count == 0 and active_count == 0:
            return {
                "changed": False,
                "msg": "discovered 0 items (no sessions)",
                "data": {"discovery": []},
            }

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "DEFAULT", "params": {}, "metrics": ["total", "running"]}
                ]
            },
        }

    # Check mode: one item
    item = params.get("item", "DEFAULT")

    # Gather session data
    active_res = ctx.run([
        "psql",
        "-t", "-A",
        "-c", "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"
    ], mutates=False)

    if active_res.rc != 0:
        active_res = ctx.run([
            "psql",
            "-t", "-A",
            "-c", "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle';"
        ], mutates=False)

    total_res = ctx.run([
        "psql",
        "-t", "-A",
        "-c", "SELECT count(*) FROM pg_stat_activity;"
    ], mutates=False)

    # Parse counts with guards instead of try/except
    total_count = 0
    if total_res.rc == 0 and total_res.stdout != None and len(total_res.stdout.strip()) > 0:
        total_str = total_res.stdout.strip()
        total_count = int(total_str) if total_str.isdigit() else 0

    active_count = 0
    if active_res.rc == 0 and active_res.stdout != None and len(active_res.stdout.strip()) > 0:
        active_str = active_res.stdout.strip()
        active_count = int(active_str) if active_str.isdigit() else 0

    # Thresholds from params
    total_warn = params.get("total", (None, None))
    if type(total_warn) == "list" or type(total_warn) == "tuple":
        total_warn = total_warn[0] if len(total_warn) > 0 else None
        total_crit = total_warn[1] if len(total_warn) > 1 else None
    else:
        total_crit = total_warn
        total_warn = None

    running_warn = params.get("running", (None, None))
    if type(running_warn) == "list" or type(running_warn) == "tuple":
        running_warn = running_warn[0] if len(running_warn) > 0 else None
        running_crit = running_warn[1] if len(running_warn) > 1 else None
    else:
        running_crit = running_warn
        running_warn = None

    # Evaluate states per metric
    # For "total"
    total_state = "OK"
    if total_crit != None and total_count >= total_crit:
        total_state = "CRIT"
    elif total_warn != None and total_count >= total_warn:
        total_state = "WARN"

    # For "running"
    running_state = "OK"
    if running_crit != None and active_count >= running_crit:
        running_state = "CRIT"
    elif running_warn != None and active_count >= running_warn:
        running_state = "WARN"

    # Determine overall worst state
    overall_state = "OK"
    if running_state == "CRIT" or total_state == "CRIT":
        overall_state = "CRIT"
    elif running_state == "WARN" or total_state == "WARN":
        overall_state = "WARN"

    # Build msg and details
    parts = []
    if total_state != "OK":
        if total_warn != None and total_crit != None:
            parts.append("Total: %d (warn/crit at %d/%d)" % (total_count, total_warn, total_crit))
        else:
            parts.append("Total: %d" % total_count)
    else:
        parts.append("Total: %d" % total_count)

    if running_state != "OK":
        if running_warn != None and running_crit != None:
            parts.append("Running: %d (warn/crit at %d/%d)" % (active_count, running_warn, running_crit))
        else:
            parts.append("Running: %d" % active_count)
    else:
        parts.append("Running: %d" % active_count)

    msg = ", ".join(parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {
                "total": total_count,
                "running": active_count,
            },
            "details": "",
        },
    }