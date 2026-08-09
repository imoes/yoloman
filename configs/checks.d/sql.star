# Translated from: checkmk.sql (cmk/plugins/sql/server_side_calls/sql.py)
# An active check that connects to a SQL database, executes a query,
# and evaluates the result against thresholds.

def main(ctx, params):
    if params.get("_discover"):
        # Active checks: verify the check_sql binary is available.
        # If not present, this check does not apply to this host.
        res = ctx.run(["check_sql", "--help"], mutates=False)
        if res.rc == 127:
            # Binary not installed - check does not apply.
            return {
                "changed": False,
                "msg": "check_sql not installed",
                "data": {"discovery": []},
            }
        # This is a configured active check: one service per configuration.
        # The item is the service description (typically "" for single-service).
        description = params.get("description", "SQL Query")
        return {
            "changed": False,
            "msg": "discovered 1 SQL check",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "warn": params.get("warn", None),
                            "crit": params.get("crit", None),
                        },
                        "metrics": [],
                    },
                ],
            },
        }

    # Check mode: run the actual check_sql command.
    # Build command arguments from params.
    dbms = params.get("dbms", "")
    name = params.get("name", "")
    user = params.get("user", "")
    sql = params.get("sql", "")
    host = params.get("host", ctx.facts().get("address", "localhost"))
    port = params.get("port", None)
    procedure = params.get("procedure", {})
    perfdata = params.get("perfdata", None)
    text_col = params.get("text", None)
    levels = params.get("levels", None)      # (metric_name, (warn, crit)) or None
    levels_low = params.get("levels_low", None)
    password_id = params.get("password_id", "")

    if not dbms or not name or not sql:
        return {
            "changed": False,
            "msg": "missing required sql check parameters",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Construct the check_sql command.
    # Password is passed via --password-id (an identifier, not the actual secret).
    argv = [
        "check_sql",
        "--hostname=" + str(host),
        "--dbms=" + str(dbms),
        "--name=" + str(name),
        "--user=" + str(user),
        "--password-id",
        str(password_id),
    ]

    # Handle port specification.
    if port != None:
        port_type = port[0]
        if port_type == "explicit":
            argv.append("--port=" + str(port[1]))
        elif port_type == "macro":
            argv.append("--port=" + str(port[1]))

    # Handle procedure.
    if procedure and procedure.get("useprocs", False):
        argv.append("--procedure")
        if "input" in procedure:
            argv.append("--inputvars=" + str(procedure["input"]))

    # Handle perfdata column.
    if perfdata:
        argv.append("--metrics=" + str(perfdata))

    # Handle levels (warning/critical thresholds).
    warn_low, crit_low = _extract_levels_starlark(levels_low)
    warn_high, crit_high = _extract_levels_starlark(levels)
    if levels or levels_low:
        argv.append("-w" + str(warn_low) + ":" + str(warn_high))
        argv.append("-c" + str(crit_low) + ":" + str(crit_high))

    # Handle text column.
    if text_col:
        argv.append("--text=" + str(text_col))

    # Append the SQL statement (escape newlines and semicolons).
    sql_escaped = sql.replace("\n", "\\n").replace(";", "\\;")
    argv.append("--sql-statement")
    argv.append(sql_escaped)

    res = ctx.run(argv, mutates=False)

    if res.rc == 127:
        return {
            "changed": False,
            "msg": "check_sql not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "check_sql binary is not installed"},
        }

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "check_sql failed (rc=%d)" % res.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    # Parse Nagios-style output: "STATE - message | perfdata"
    stdout = res.stdout.strip()
    state = "OK"
    msg = stdout
    metrics = {}

    # Split on first " - " to find the state.
    dash_idx = stdout.find(" - ")
    if dash_idx != -1:
        state_str = stdout[:dash_idx].strip().upper()
        rest = stdout[dash_idx + 3:]
        if state_str == "OK":
            state = "OK"
        elif state_str == "WARNING":
            state = "WARN"
        elif state_str == "CRITICAL":
            state = "CRIT"
        else:
            state = "UNKNOWN"
        msg = rest
    else:
        # No state prefix found, assume OK with raw output.
        msg = stdout

    # Parse perfdata section (after " | ").
    pipe_idx = msg.rfind(" | ")
    if pipe_idx != -1:
        perfdata_str = msg[pipe_idx + 3:]
        msg = msg[:pipe_idx]
        metrics = _parse_perfdata(perfdata_str)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": stdout,
        },
    }


def _extract_levels_starlark(levels):
    """Extract (warn, crit) from levels tuple.
    levels is either None, or ('no_levels', None), or ('fixed', (warn, crit)).
    """
    if levels == None:
        return 0.0, 0.0
    if type(levels) == "tuple" and len(levels) == 2:
        level_type = levels[0]
        values = levels[1]
        if level_type == "fixed" and values != None:
            v = values
            if type(v) == "tuple" and len(v) == 2:
                return float(v[0]), float(v[1])
        if level_type == "no_levels":
            return 0.0, 0.0
    return 0.0, 0.0


def _parse_perfdata(perfdata_str):
    """Parse Nagios perfdata string into metrics dict.
    Format: 'metric_name=value;warn;crit;min;max metric2=value2...'
    We extract name -> value (float).
    """
    result = {}
    parts = perfdata_str.split()
    for part in parts:
        eq_idx = part.find("=")
        if eq_idx == -1:
            continue
        name = part[:eq_idx]
        value_str = part[eq_idx + 1:]
        # Find the start of thresholds (first semicolon).
        semicolon_idx = value_str.find(";")
        if semicolon_idx != -1:
            value_str = value_str[:semicolon_idx]
        try_value = value_str
        # Try to parse as float, handling potential quotes or units.
        # Remove common trailing/leading characters.
        cleaned = try_value.strip().strip("'").strip('"')
        if cleaned == "":
            continue
        # Check if it looks like a number.
        num_str = cleaned
        # Handle negative numbers.
        is_num = True
        test_str = num_str
        if test_str.startswith("-"):
            test_str = test_str[1:]
        if test_str == "":
            is_num = False
        else:
            # Check if all chars are digits or decimal point.
            has_digit = False
            for ch in test_str:
                if ch == ".":
                    continue
                if ch < "0" or ch > "9":
                    is_num = False
                    break
                has_digit = True
            if not has_digit:
                is_num = False
        if is_num:
            result[name] = float(num_str)
        else:
            result[name] = cleaned
    return result