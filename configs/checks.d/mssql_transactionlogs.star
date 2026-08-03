# Copyright (C) 2019 Checkmk GmbH - License: GNU General Public License v2
# Translated to Starlark for the yolo-man agent. READ-ONLY: never mutates.

# Default check parameters (from Checkmk source: check_default_parameters)
DEFAULT_USED_LEVELS = [80.0, 90.0]  # warn, crit in percent
DEFAULT_SUMMARIZE_TXLOGS = False

# Metric name for used percentage
METRIC_USED_PERCENT = "used_percent"

def main(ctx, params):
    if params.get("_discover"):
        tools = _find_mssql_tools(ctx)
        if tools == None:
            return {
                "changed": False,
                "msg": "MSSQL tools not found; no transaction logs discovered",
                "data": {"discovery": []},
            }

        rows = _query_transaction_logs(ctx, tools)
        if rows == None:
            return {
                "changed": False,
                "msg": "failed to query MSSQL transaction logs",
                "data": {"discovery": []},
            }

        summarize = params.get("summarize_transactionlogs", DEFAULT_SUMMARIZE_TXLOGS)
        discovery = []
        seen = set()
        for inst_db_fn in rows:
            inst = inst_db_fn[0]
            database = inst_db_fn[1]
            file_name = inst_db_fn[2]
            item = _format_item(inst, database, None if summarize else file_name)
            if item in seen:
                continue
            seen.add(item)
            discovery.append({
                "item": item,
                "params": {"used_levels": DEFAULT_USED_LEVELS},
                "metrics": [METRIC_USED_PERCENT],
            })
        return {
            "changed": False,
            "msg": "discovered %d MSSQL transaction log(s)" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    tools = _find_mssql_tools(ctx)
    if tools == None:
        return {
            "changed": False,
            "msg": "MSSQL tools not found on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _query_transaction_logs(ctx, tools)
    if rows == None:
        return {
            "changed": False,
            "msg": "failed to query MSSQL transaction logs",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    instances = []
    for inst_db_fn in rows:
        inst = inst_db_fn[0]
        database = inst_db_fn[1]
        file_name = inst_db_fn[2]
        if _format_item(inst, database, file_name) == item or \
           _format_item(inst, database, None) == item:
            instances.append((inst, database, file_name))

    if len(instances) == 0:
        return {
            "changed": False,
            "msg": "no transaction log found for item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    file_data = _query_file_details(ctx, tools, instances)
    if file_data == None:
        return {
            "changed": False,
            "msg": "failed to query MSSQL file details",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used_sum = 0.0
    allocated_sum = 0.0
    max_sum = 0.0
    unlimited = False

    for inst_db_fn in instances:
        inst = inst_db_fn[0]
        database = inst_db_fn[1]
        file_name = inst_db_fn[2]
        data = file_data.get(_format_item(inst, database, file_name))
        if data == None:
            continue
        if data["unlimited"]:
            unlimited = True
        allocated = data["allocated_size"]
        if allocated == None:
            allocated = 0.0
        used = data["used_size"]
        if used == None:
            used = 0.0
        allocated_sum += allocated
        used_sum += used

        max_size = data["max_size"]
        if max_size == None:
            max_size = 0.0
        if data["unlimited"] and data["free_size"] != None:
            max_size = max(max_size, data["free_size"] + used)
        max_sum += max_size

    raw_levels = params.get("used_levels", DEFAULT_USED_LEVELS)
    warn_pct, crit_pct = _coerce_levels(raw_levels, DEFAULT_USED_LEVELS)

    if max_sum > 0:
        used_pct = used_sum * 100.0 / max_sum
    else:
        used_pct = 0.0

    state = _grade_upper(used_pct, warn_pct, crit_pct)

    msg = "Used: %s of %s (%f%%)" % (
        _render_bytes(used_sum),
        _render_bytes(max_sum),
        used_pct,
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {METRIC_USED_PERCENT: used_pct},
            "details": msg,
        },
    }


def _find_mssql_tools(ctx):
    res = ctx.run(["sh", "-c", "command -v sqlcmd"], mutates=False)
    if res.rc == 0 and res.stdout.strip() != "":
        sqlcmd_path = res.stdout.strip()
        return {"tool": "sqlcmd", "path": sqlcmd_path}
    return None

def _query_transaction_logs(ctx, tools):
    path = tools["path"]
    q = "SET NOCOUNT ON; " + \
        "DECLARE @db sysname; " + \
        "DECLARE db_cur CURSOR FOR SELECT name FROM sys.databases; " + \
        "CREATE TABLE #logfiles (inst sysname, db sysname, fname sysname); " + \
        "OPEN db_cur; " + \
        "FETCH NEXT FROM db_cur INTO @db; " + \
        "WHILE @@FETCH_STATUS = 0 BEGIN " + \
        "  INSERT INTO #logfiles " + \
        "  EXEC('USE [' + @db + ']; SELECT DB_NAME(), name, physical_name " + \
        "    FROM sys.database_files WHERE type_desc = ''LOG'';'); " + \
        "  FETCH NEXT FROM db_cur INTO @db; " + \
        "END; " + \
        "CLOSE db_cur; DEALLOCATE db_cur; " + \
        "SELECT inst, db, fname FROM #logfiles;"
    res = ctx.run(
        [path, "-S", "localhost", "-E", "-Q", q, "-W", "-s", " "],
        mutates=False,
    )
    if res.rc != 0:
        return None

    rows = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 2)
        if len(parts) < 3:
            continue
        database = parts[0]
        file_name = parts[1]
        rows.append([None, database, file_name])
    return rows

def _query_file_details(ctx, tools, instances):
    path = tools["path"]
    result = {}
    for inst_db_fn in instances:
        inst = inst_db_fn[0]
        database = inst_db_fn[1]
        file_name = inst_db_fn[2]
        q = "USE [" + database + "]; " + \
            "SELECT name, physical_name, type_desc, " + \
            "max_size, size*8.0/1024 AS allocated_mb, " + \
            "CAST(FILEPROPERTY(name, 'SpaceUsed') AS float)*8.0/1024 AS used_mb, " + \
            "is_percent_growth, max_size " + \
            "FROM sys.database_files WHERE name = '" + file_name + "';"
        res = ctx.run(
            [path, "-S", "localhost", "-E", "-Q", q, "-W", "-s", " "],
            mutates=False,
        )
        if res.rc != 0:
            continue

        lines = res.stdout.splitlines()
        if len(lines) < 2:
            continue
        data_line = lines[1].split(" ")
        if len(data_line) < 6:
            continue

        max_size_str = data_line[3]
        allocated_str = data_line[4]
        used_str = data_line[5]
        if not _is_numeric(max_size_str) or not _is_numeric(allocated_str) or not _is_numeric(used_str):
            continue

        max_size = float(max_size_str)
        allocated = float(allocated_str)
        used = float(used_str)

        unlimited = max_size < 0
        max_bytes = None
        if not unlimited:
            max_bytes = max_size * 1024.0 * 1024.0
        allocated_bytes = allocated * 1024.0 * 1024.0
        used_bytes = used * 1024.0 * 1024.0

        key = _format_item(inst, database, file_name)
        result[key] = {
            "unlimited": unlimited,
            "max_size": max_bytes,
            "allocated_size": allocated_bytes,
            "used_size": used_bytes,
            "free_size": None,
        }
    return result

def _format_item(inst, database, file_name):
    if inst == None:
        if file_name == None:
            return "%s.NULL" % database
        return "%s.%s" % (database, file_name)
    if file_name == None:
        return "%s.%s" % (inst, database)
    return "%s.%s.%s" % (inst, database, file_name)

def _grade_upper(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _coerce_levels(raw, default):
    if type(raw) == "list":
        if len(raw) >= 2 and _is_numeric(raw[0]) and _is_numeric(raw[1]):
            return (float(raw[0]), float(raw[1]))
        if len(raw) > 0 and type(raw[0]) == "list":
            for level_set in raw:
                if type(level_set) == "list" and len(level_set) >= 2:
                    return (float(level_set[0]), float(level_set[1]))
    return (default[0], default[1])

def _is_numeric(s):
    if s == None:
        return False
    if type(s) == "int" or type(s) == "float":
        return True
    stripped = s.strip() if type(s) == "string" else ""
    if stripped == "":
        return False
    # Check for valid float format: optional sign, digits, optional decimal
    parts = stripped.split(".")
    if len(parts) > 2:
        return False
    for part in parts:
        digits = part.lstrip("+-")
        if digits == "":
            continue
        if not digits.isdigit():
            return False
    # Must contain at least one digit
    has_digit = False
    for c in stripped:
        if c.isdigit():
            has_digit = True
            break
    return has_digit

def _render_bytes(n):
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    size = float(n)
    idx = 0
    limit = len(units) - 1
    while size >= 1024.0 and idx < limit:
        size = size / 1024.0
        idx = idx + 1
    if idx == 0:
        return "%d %s" % (int(size), units[idx])
    return "%f %s" % (size, units[idx])