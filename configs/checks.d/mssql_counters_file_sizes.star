def get_int(counters, key):
    v = counters.get(key)
    if v == None:
        return 0
    if type(v) == "string":
        if v.isdigit():
            return int(v)
        return 0
    return int(v)

def render_bytes(v):
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    size = float(v)
    idx = 0
    while idx < len(units) - 1 and size >= 1024:
        size = size / 1024
        idx = idx + 1
    if idx == 0:
        return "%d B" % int(size)
    return "%f %s" % (size, units[idx])

def render_percent(v):
    return "%f%%" % v

def discovery_mssql_counters_file_sizes(section):
    found = {}
    for key in section:
        data = section[key]
        if not type(data) == "dict":
            continue
        has_required = True
        for req in ["data_file(s)_size_(kb)", "log_file(s)_size_(kb)", "log_file(s)_used_size_(kb)"]:
            if req not in data:
                has_required = False
        if not has_required:
            continue
        inst = key[0]
        db = key[1]
        item = inst + " " + db
        found[item] = True
    return found

def check_mssql_file_sizes_item(item, params, section):
    found = discovery_mssql_counters_file_sizes(section)
    if item not in found:
        return {"state": "UNKNOWN", "msg": "no such database: " + item, "metrics": {}, "details": ""}

    data = None
    for key in section:
        candidate = key[0] + " " + key[1]
        if candidate == item:
            data = section[key]
            break
    if data == None:
        return {"state": "UNKNOWN", "msg": "no data for database: " + item, "metrics": {}, "details": ""}

    log_files_size = get_int(data, "log_file(s)_size_(kb)") * 1024
    data_files_size = get_int(data, "data_file(s)_size_(kb)") * 1024

    metrics = {}
    states = []
    summaries = []

    dw = params.get("data_files", None)
    data_state = "OK"
    if dw != None:
        d_warn = dw[0] if type(dw) == "list" and len(dw) > 0 else None
        d_crit = dw[1] if type(dw) == "list" and len(dw) > 1 else None
        if d_crit != None and data_files_size >= d_crit:
            data_state = "CRIT"
        elif d_warn != None and data_files_size >= d_warn:
            data_state = "WARN"
    states.append(data_state)
    summaries.append("Data files: " + render_bytes(data_files_size))
    metrics["data_files"] = data_files_size

    lw = params.get("log_files", None)
    log_state = "OK"
    if lw != None:
        l_warn = lw[0] if type(lw) == "list" and len(lw) > 0 else None
        l_crit = lw[1] if type(lw) == "list" and len(lw) > 1 else None
        if l_crit != None and log_files_size >= l_crit:
            log_state = "CRIT"
        elif l_warn != None and log_files_size >= l_warn:
            log_state = "WARN"
    states.append(log_state)
    summaries.append("Log files total: " + render_bytes(log_files_size))
    metrics["log_files"] = log_files_size

    log_files_used = data.get("log_file(s)_used_size_(kb)")
    if log_files_used == None:
        combined = "OK"
        for s in states:
            if s == "CRIT":
                combined = "CRIT"
            elif s == "WARN" and combined == "OK":
                combined = "WARN"
        return {
            "state": combined,
            "msg": ", ".join(summaries),
            "metrics": metrics,
            "details": "",
        }

    log_files_used = int(log_files_used) * 1024
    levels_upper = params.get("log_files_used", None)

    used_state = "OK"
    if levels_upper != None:
        lu_warn = levels_upper[0] if type(levels_upper) == "list" and len(levels_upper) > 0 else None
        lu_crit = levels_upper[1] if type(levels_upper) == "list" and len(levels_upper) > 1 else None
        if lu_warn != None and type(lu_warn) == "float" and log_files_size:
            pct = 100 * log_files_used / log_files_size
            used_state = "OK"
            if lu_crit != None and pct >= lu_crit:
                used_state = "CRIT"
            elif pct >= lu_warn:
                used_state = "WARN"
            metrics["log_files_used_percent"] = pct
            summaries.append("Log files used: " + render_percent(pct))
        else:
            used_state = "OK"
            if lu_crit != None and log_files_used >= lu_crit:
                used_state = "CRIT"
            elif lu_warn != None and log_files_used >= lu_warn:
                used_state = "WARN"
            summaries.append("Log files used: " + render_bytes(log_files_used))
    else:
        summaries.append("Log files used: " + render_bytes(log_files_used))
    states.append(used_state)
    metrics["log_files_used"] = log_files_used

    combined = "OK"
    for s in states:
        if s == "CRIT":
            combined = "CRIT"
        elif s == "WARN" and combined == "OK":
            combined = "WARN"
    return {
        "state": combined,
        "msg": ", ".join(summaries),
        "metrics": metrics,
        "details": "",
    }

def main(ctx, params):
    if params.get("_discover"):
        sqlcmd = ctx.run(["which", "sqlcmd"], mutates=False)
        if sqlcmd.rc != 0:
            tools = ctx.run(["ls", "/opt/mssql-tools/bin/"], mutates=False)
            if tools.rc != 0:
                return {"changed": False, "msg": "no mssql tools found", "data": {"discovery": []}}

        sqlserv = ctx.run(["which", "sqlservr"], mutates=False)
        if sqlserv.rc != 0:
            isactive = ctx.run(["systemctl", "is-active", "mssql-server"], mutates=False)
            if isactive.rc != 0:
                return {"changed": False, "msg": "no mssql instance found", "data": {"discovery": []}}

        qres = ctx.run(
            ["sqlcmd", "-S", "localhost", "-E", "-Q",
             "SELECT name FROM sys.databases", "-W", "-s", ";"],
            mutates=False,
        )
        if qres.rc != 0:
            return {"changed": False, "msg": "cannot query mssql", "data": {"discovery": []}}

        section = {}
        lines = qres.stdout.splitlines()
        header_parsed = False
        for line in lines:
            parts = line.split(";")
            if not header_parsed:
                header_parsed = True
                continue
            db = parts[0].strip() if len(parts) > 0 else ""
            if db == "":
                continue
            section[("MSSQL", db)] = {
                "data_file(s)_size_(kb)": 0,
                "log_file(s)_size_(kb)": 0,
                "log_file(s)_used_size_(kb)": 0,
            }

        if len(section) == 0:
            return {"changed": False, "msg": "no databases found", "data": {"discovery": []}}

        discovery = []
        for key in section:
            inst = key[0]
            db = key[1]
            item = inst + " " + db
            discovery.append({
                "item": item,
                "params": {"warn": None, "crit": None},
                "metrics": ["data_files", "log_files", "log_files_used"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no database item specified"},
        }

    sqlcmd = ctx.run(["which", "sqlcmd"], mutates=False)
    if sqlcmd.rc != 0:
        return {
            "changed": False,
            "msg": "sqlcmd not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "sqlcmd not installed"},
        }

    isactive = ctx.run(["systemctl", "is-active", "mssql-server"], mutates=False)
    if isactive.rc != 0:
        return {
            "changed": False,
            "msg": "mssql-server not running",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "mssql-server service not active"},
        }

    qres = ctx.run(
        ["sqlcmd", "-S", "localhost", "-E", "-Q",
         "SELECT DB_NAME(database_id) AS db, type_desc, size*8/1024 AS size_mb FROM sys.master_files",
         "-W", "-s", ";"],
        mutates=False,
    )
    if qres.rc != 0:
        return {
            "changed": False,
            "msg": "cannot query mssql for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "sqlcmd query failed"},
        }

    section = {}
    lines = qres.stdout.splitlines()
    db_idx = -1
    type_idx = -1
    size_idx = -1
    header_parsed = False
    for line in lines:
        parts = line.split(";")
        if not header_parsed:
            for idx, p in enumerate(parts):
                pname = p.strip()
                if pname == "db":
                    db_idx = idx
                elif pname == "type_desc":
                    type_idx = idx
                elif pname == "size_mb":
                    size_idx = idx
            if db_idx >= 0:
                header_parsed = True
            continue
        if len(parts) < 3:
            continue
        db = parts[db_idx].strip()
        type_desc = parts[type_idx].strip()
        size_mb = parts[size_idx].strip()
        if size_mb == "" or not size_mb.isdigit():
            continue
        size_kb = int(size_mb) * 128
        key = ("MSSQL", db)
        if key not in section:
            section[key] = {}
        if type_desc == "ROWS":
            section[key]["data_file(s)_size_(kb)"] = size_kb
        elif type_desc == "LOG":
            section[key]["log_file(s)_size_(kb)"] = size_kb

    qres2 = ctx.run(
        ["sqlcmd", "-S", "localhost", "-E", "-Q",
         "SELECT name, CAST(size * 8 / 1024.0 AS INT) AS log_used_mb FROM sys.databases WHERE state = 0",
         "-W", "-s", ";"],
        mutates=False,
    )
    if qres2.rc == 0:
        for line in qres2.stdout.splitlines():
            parts = line.split(";")
            if len(parts) < 2:
                continue
            db = parts[0].strip()
            log_used = parts[1].strip()
            if log_used == "" or not log_used.isdigit():
                continue
            key = ("MSSQL", db)
            if key in section:
                section[key]["log_file(s)_used_size_(kb)"] = int(log_used) * 128

    section_dict = {}
    for key in section:
        item_name = key[0] + " " + key[1]
        section_dict[key] = section[key]

    result = check_mssql_file_sizes_item(item, params, section_dict)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"],
        },
    }