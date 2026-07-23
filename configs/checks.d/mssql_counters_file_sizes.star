COUNTER_DATA = "Data File(s) Size (KB)"
COUNTER_LOG = "Log File(s) Size (KB)"
COUNTER_LOG_USED = "Log File(s) Used Size (KB)"

_STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
_DIGIT_CHARS = "0123456789"

_BASE_QUERY = "SET NOCOUNT ON; SELECT RTRIM(object_name), RTRIM(counter_name), RTRIM(instance_name), cntr_value FROM sys.dm_os_performance_counters WHERE counter_name IN ('Data File(s) Size (KB)', 'Log File(s) Size (KB)', 'Log File(s) Used Size (KB)') AND instance_name <> '_Total'"

def _is_int_str(s):
    if s == "":
        return False
    start = 1 if s[0] == "-" else 0
    if start >= len(s):
        return False
    for i in range(start, len(s)):
        if s[i] not in _DIGIT_CHARS:
            return False
    return True

def _worse(a, b):
    if _STATE_RANK.get(a, 0) >= _STATE_RANK.get(b, 0):
        return a
    return b

def _fmt_bytes(b):
    b = float(b)
    if b >= 1073741824.0:
        return "%f GiB" % (b / 1073741824.0)
    if b >= 1048576.0:
        return "%f MiB" % (b / 1048576.0)
    if b >= 1024.0:
        return "%f KiB" % (b / 1024.0)
    return "%d B" % int(b)

def _prefix_to_raw(instance_prefix):
    if instance_prefix.startswith("MSSQL_"):
        raw = instance_prefix[6:]
        if raw == "MSSQLSERVER":
            return ""
        return raw
    return ""

def _sqlcmd_args(host, raw_instance, username, password):
    server = host if raw_instance == "" else host + "\\" + raw_instance
    args = ["sqlcmd", "-S", server, "-h", "-1", "-s", "|", "-W", "-l", "30"]
    if username != "":
        return args + ["-U", username, "-P", password]
    return args + ["-E"]

def _parse_rows(stdout):
    result = {}
    for line in stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        if line.startswith("-") or "rows affected" in line:
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        obj_name = parts[0].strip()
        counter_name = parts[1].strip()
        db_name = parts[2].strip()
        cntr_str = parts[3].strip()
        if db_name == "" or db_name == "_Total":
            continue
        if not _is_int_str(cntr_str):
            continue
        cntr_value = int(cntr_str)
        obj_part = obj_name.split(":")[0].strip() if ":" in obj_name else obj_name
        if obj_part.startswith("MSSQL$"):
            inst_prefix = "MSSQL_" + obj_part[6:]
        elif obj_part == "SQLServer":
            inst_prefix = "MSSQL_MSSQLSERVER"
        else:
            inst_prefix = obj_part.replace("$", "_")
        key = inst_prefix + " " + db_name
        if key not in result:
            result[key] = {}
        result[key][counter_name] = cntr_value
    return result

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "")
    password = params.get("password", "")

    if params.get("_discover"):
        raw_instance = params.get("instance", "")
        args = _sqlcmd_args(host, raw_instance, username, password)
        res = ctx.run(args + ["-Q", _BASE_QUERY], mutates=False, ok_codes=[0, 1])
        data = _parse_rows(res.stdout)
        discovery = []
        for key in sorted(data.keys()):
            c = data[key]
            if COUNTER_DATA in c and COUNTER_LOG in c:
                discovery.append({
                    "item": key,
                    "params": {},
                    "metrics": ["data_files", "log_files", "log_files_used"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    sep = item.find(" ")
    if sep < 0:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    inst_prefix = item[:sep]
    db_name = item[sep + 1:]
    raw_instance = _prefix_to_raw(inst_prefix)
    db_query = _BASE_QUERY + " AND RTRIM(instance_name) = N'" + db_name.replace("'", "''") + "'"
    args = _sqlcmd_args(host, raw_instance, username, password)
    res = ctx.run(args + ["-Q", db_query], mutates=False, ok_codes=[0, 1])

    if res.rc != 0 and res.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "MSSQL error: " + res.stderr[:200],
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    data = _parse_rows(res.stdout)
    item_counters = data.get(item, {})
    if not item_counters:
        return {
            "changed": False,
            "msg": "no data for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data_files = float(item_counters.get(COUNTER_DATA, 0)) * 1024.0
    log_files = float(item_counters.get(COUNTER_LOG, 0)) * 1024.0
    log_used_kb = item_counters.get(COUNTER_LOG_USED)

    metrics = {"data_files": data_files, "log_files": log_files}
    state = "OK"
    msg_parts = []

    data_levels = params.get("data_files")
    if data_levels != None and data_levels[0] != None and data_levels[1] != None:
        if data_files >= data_levels[1]:
            state = _worse(state, "CRIT")
        elif data_files >= data_levels[0]:
            state = _worse(state, "WARN")
    msg_parts.append("Data files: " + _fmt_bytes(data_files))

    log_levels = params.get("log_files")
    if log_levels != None and log_levels[0] != None and log_levels[1] != None:
        if log_files >= log_levels[1]:
            state = _worse(state, "CRIT")
        elif log_files >= log_levels[0]:
            state = _worse(state, "WARN")
    msg_parts.append("Log files total: " + _fmt_bytes(log_files))

    if log_used_kb != None:
        log_used = float(log_used_kb) * 1024.0
        metrics["log_files_used"] = log_used
        lu_levels = params.get("log_files_used")
        if lu_levels != None and lu_levels[0] != None and lu_levels[1] != None:
            lu_w = lu_levels[0]
            lu_c = lu_levels[1]
            if type(lu_w) == "float" and log_files > 0.0:
                used_pct = 100.0 * log_used / log_files
                if used_pct >= lu_c:
                    state = _worse(state, "CRIT")
                elif used_pct >= lu_w:
                    state = _worse(state, "WARN")
                msg_parts.append("Log files used: %f%%" % used_pct)
            else:
                if log_used >= lu_c:
                    state = _worse(state, "CRIT")
                elif log_used >= lu_w:
                    state = _worse(state, "WARN")
                msg_parts.append("Log files used: " + _fmt_bytes(log_used))
        else:
            msg_parts.append("Log files used: " + _fmt_bytes(log_used))

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }