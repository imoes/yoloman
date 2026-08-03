def main(ctx, params):
    # --- Discovery: determine which MySQL check plugins apply ---
    if params.get("_discover"):
        # Probe for mysqld binary to establish MySQL is actually present
        has_mysql = False
        res = ctx.run(["which", "mysqld"], mutates=False)
        if res.rc == 0 and res.stdout != "":
            has_mysql = True
        res = ctx.run(["which", "mariadbd"], mutates=False)
        if res.rc == 0 and res.stdout != "":
            has_mysql = True
        res = ctx.run(["which", "mysql"], mutates=False)
        if res.rc == 0 and res.stdout != "":
            has_mysql = True
        if not has_mysql:
            return {"changed": False, "msg": "no MySQL found on host",
                    "data": {"discovery": []}}

        # Gather MySQL server status variables via mysql CLI
        data = _gather_mysql(ctx)
        if not data:
            return {"changed": False, "msg": "no MySQL data",
                    "data": {"discovery": []}}

        discovery = []
        # mysql version check: single-service (item "")
        discover_version(data, discovery)
        # mysql_sessions: per-instance, item = instance name
        discover_sessions(data, discovery)
        # mysql_innodb_io: per-instance
        discover_innodb_io(data, discovery)
        # mysql_connections: per-instance
        discover_connections(data, discovery)
        # galerasync, galeradonor, galerastartup, galerasize, galerastatus
        discover_galera(data, discovery)

        return {"changed": False,
                "msg": "discovered %d mysql items" % len(discovery),
                "data": {"discovery": discovery}}

    # --- Check mode: check a specific plugin/item ---
    plugin = params.get("plugin", "mysql")
    item = params.get("item", "")
    data = _gather_mysql(ctx)
    if not data:
        return {"changed": False, "msg": "no MySQL data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if plugin == "mysql_sessions":
        return check_mysql_sessions(ctx, params, data, item)
    if plugin == "mysql_innodb_io":
        return check_mysql_iostat(ctx, params, data, item)
    if plugin == "mysql_connections":
        return check_mysql_connections(ctx, params, data, item)
    if plugin == "mysql_galerasync":
        return check_mysql_galerasync(data, item)
    if plugin == "mysql_galeradonor":
        return check_mysql_galeradonor(ctx, params, data, item)
    if plugin == "mysql_galerastartup":
        return check_mysql_galerastartup(data, item)
    if plugin == "mysql_galerasize":
        return check_mysql_galerasize(ctx, params, data, item)
    if plugin == "mysql_galerastatus":
        return check_mysql_galerastatus(data, item)

    # Default: mysql version (single-service, item ignored)
    return check_mysql_version(data)


def _gather_mysql(ctx):
    # Try connecting and fetching SHOW GLOBAL STATUS
    host = ctx.facts().get("hostname", "localhost")
    res = ctx.run(
        ["mysql", "--connect-timeout=5", "-N", "-B", "-e",
         "SHOW GLOBAL STATUS; SHOW GLOBAL VARIABLES LIKE 'version'; SHOW GLOBAL VARIABLES LIKE 'wsrep%';"],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 127:
        return {}
    if res.rc == 127:
        return {}
    if res.stdout == "":
        return {}

    lines = res.stdout.splitlines()
    # Parse result sets: SHOW GLOBAL STATUS -> Variable_name, Value
    data = {}
    idx = 0
    # First table: Global Status
    while idx < len(lines):
        line = lines[idx]
        idx += 1
        if line.strip() == "":
            idx += 1  # skip empty line / column count marker
            break
        parts = line.split("\t")
        if len(parts) >= 2:
            data[parts[0]] = parts[1]

    # Second table: version variable
    while idx < len(lines):
        line = lines[idx]
        idx += 1
        if line.strip() == "":
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            data[parts[0]] = parts[1]

    # Third table: wsrep% variables
    while idx < len(lines):
        line = lines[idx]
        idx += 1
        if line.strip() == "":
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            data[parts[0]] = parts[1]

    # Wrap under an instance key; use "mysql" as the single instance
    return {"mysql": data}


def check_mysql_version(section):
    data = section.get("mysql")
    if data == None:
        return {"changed": False, "msg": "MySQL version unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    version = data.get("version", "")
    if version == "":
        return {"changed": False, "msg": "MySQL version unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Version: %s" % version,
            "data": {"state": "OK", "metrics": {}}}


def discover_version(data, discovery):
    instance = "mysql"
    idata = data.get(instance)
    if idata == None:
        return
    if "version" in idata:
        discovery.append({"item": instance, "params": {},
                          "metrics": []})


def discover_sessions(data, discovery):
    instance = "mysql"
    idata = data.get(instance)
    if idata == None:
        return
    needed = ["Threads_connected", "Threads_running", "Connections"]
    ok = True
    for k in needed:
        if k not in idata:
            ok = False
    if ok:
        discovery.append({"item": instance, "params": {},
                          "metrics": ["total_sessions", "running_sessions", "connect_rate"]})


def check_mysql_sessions(ctx, params, section, item):
    idata = section.get(item)
    if idata == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    total = _to_int(idata.get("Threads_connected", 0))
    running = _to_int(idata.get("Threads_running", 0))

    # Rate for Connections (best-effort; we compute delta-like estimate from value)
    connects = _to_int(idata.get("Connections", 0))

    levels_total = params.get("total")
    levels_running = params.get("running")
    levels_conn = params.get("connections")

    state = "OK"
    metrics = {"total_sessions": total, "running_sessions": running, "connect_rate": float(connects)}

    if levels_running != None:
        state = _grade_upper(running, levels_running, state)
    if levels_total != None:
        state = _grade_upper(total, levels_total, state)

    msg = "%d total, %d running, %d connects" % (total, running, connects)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def discover_innodb_io(data, discovery):
    instance = "mysql"
    idata = data.get(instance)
    if idata == None:
        return
    if "Innodb_data_read" in idata and "Innodb_data_written" in idata:
        discovery.append({"item": instance, "params": {},
                          "metrics": ["read", "write"]})


def check_mysql_iostat(ctx, params, section, item):
    idata = section.get(item)
    if idata == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    if "Innodb_data_read" not in idata or "Innodb_data_written" not in idata:
        return {"changed": False, "msg": "InnoDB IO data missing",
                "data": {"state": "UNKNOWN", "metrics": {}}}

    read_val = _to_int(idata.get("Innodb_data_read", 0))
    write_val = _to_int(idata.get("Innodb_data_written", 0))

    avg_range = params.get("average", 0)
    metrics = {"read": read_val, "write": write_val}
    state = "OK"

    for name, val in [("read", read_val), ("write", write_val)]:
        levels = params.get(name + "_bytes")
        if levels != None and len(levels) >= 2:
            w = levels[0]
            c = levels[1]
            if val >= c:
                state = _worse(state, "CRIT")
            elif val >= w:
                state = _worse(state, "WARN")

    msg = "InnoDB IO read %d, write %d bytes" % (read_val, write_val)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def discover_connections(data, discovery):
    instance = "mysql"
    idata = data.get(instance)
    if idata == None:
        return
    needed = ["Max_used_connections", "max_connections", "Threads_connected"]
    ok = True
    for k in needed:
        if k not in idata:
            ok = False
    if ok:
        discovery.append({"item": instance, "params": {},
                          "metrics": ["connections_max_used", "connections_max", "connections_conn_threads",
                                      "connections_perc_used", "connections_perc_conn_threads"]})


def check_mysql_connections(ctx, params, section, item):
    idata = section.get(item)
    if idata == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    if "Max_used_connections" not in idata:
        return {"changed": False, "msg": "Connection information is missing",
                "data": {"state": "UNKNOWN", "metrics": {}}}

    conn = _to_int(idata.get("Max_used_connections", 0))
    conn_threads = _to_int(idata.get("Threads_connected", 0))
    max_conn = _to_int(idata.get("max_connections", 0))

    if max_conn == 0:
        return {"changed": False, "msg": "max_connections is zero",
                "data": {"state": "UNKNOWN", "metrics": {}}}

    perc_used = conn * 100.0 / max_conn
    perc_threads = conn_threads * 100.0 / max_conn

    metrics = {
        "connections_max_used": conn,
        "connections_max": max_conn,
        "connections_conn_threads": conn_threads,
        "connections_perc_used": perc_used,
        "connections_perc_conn_threads": perc_threads,
    }

    state = "OK"
    lvls = params.get("perc_used")
    if lvls != None:
        state = _grade_upper(perc_used, lvls, state)
    lvls2 = params.get("perc_conn_threads")
    if lvls2 != None:
        state = _grade_upper(perc_threads, lvls2, state)

    msg = "%f%% used (max %d/%d), %f%% currently open" % (perc_used, conn, max_conn, perc_threads)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _has_wsrep_provider(data):
    val = data.get("wsrep_provider", "")
    return val != "" and val != "none"


def discover_galera(data, discovery):
    instance = "mysql"
    idata = data.get(instance)
    if idata == None:
        return
    if not _has_wsrep_provider(idata):
        return
    if "wsrep_local_state_comment" in idata:
        discovery.append({"item": instance, "params": {},
                          "metrics": []})
    if "wsrep_sst_donor" in idata:
        discovery.append({"item": instance,
                          "params": {"wsrep_sst_donor": idata.get("wsrep_sst_donor", "")},
                          "metrics": []})
    if "wsrep_cluster_address" in idata:
        discovery.append({"item": instance, "params": {},
                          "metrics": []})
    if "wsrep_cluster_size" in idata:
        discovery.append({"item": instance,
                          "params": {"invsize": _to_int(idata.get("wsrep_cluster_size", 0))},
                          "metrics": []})
    if "wsrep_cluster_status" in idata:
        discovery.append({"item": instance, "params": {},
                          "metrics": []})


def check_mysql_galerasync(section, item):
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    comment = data.get("wsrep_local_state_comment", "")
    if comment == "":
        return {"changed": False, "msg": "wsrep_local_state_comment missing",
                "data": {"state": "UNKNOWN", "metrics": {}}}
    state = "OK" if comment == "Synced" else "CRIT"
    return {"changed": False,
            "msg": "WSREP local state comment: %s" % comment,
            "data": {"state": state, "metrics": {}}}


def check_mysql_galeradonor(ctx, params, section, item):
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    donor = data.get("wsrep_sst_donor", "")
    if donor == "":
        return {"changed": False, "msg": "wsrep_sst_donor missing",
                "data": {"state": "UNKNOWN", "metrics": {}}}
    state = "OK"
    msg = "WSREP SST donor: %s" % donor
    p_donor = params.get("wsrep_sst_donor", "")
    if donor != p_donor and p_donor != "":
        state = "WARN"
        msg += " (at discovery: %s)" % p_donor
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}}}


def check_mysql_galerastartup(section, item):
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    addr = data.get("wsrep_cluster_address", "")
    if addr == "":
        return {"changed": False, "msg": "wsrep_cluster_address missing",
                "data": {"state": "UNKNOWN", "metrics": {}}}
    if addr == "gcomm://":
        return {"changed": False, "msg": "WSREP cluster address is empty",
                "data": {"state": "CRIT", "metrics": {}}}
    return {"changed": False,
            "msg": "WSREP cluster address: %s" % addr,
            "data": {"state": "OK", "metrics": {}}}


def check_mysql_galerasize(ctx, params, section, item):
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    size = data.get("wsrep_cluster_size", "")
    if size == "":
        return {"changed": False, "msg": "wsrep_cluster_size missing",
                "data": {"state": "UNKNOWN", "metrics": {}}}
    size_val = _to_int(size)
    state = "OK"
    msg = "WSREP cluster size: %d" % size_val
    p_size = params.get("invsize", None)
    if p_size != None and size_val != p_size:
        state = "CRIT"
        msg += " (at discovery: %d)" % p_size
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"wsrep_cluster_size": size_val}}}


def check_mysql_galerastatus(section, item):
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no data for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}}}
    status = data.get("wsrep_cluster_status", "")
    if status == "":
        return {"changed": False, "msg": "wsrep_cluster_status missing",
                "data": {"state": "UNKNOWN", "metrics": {}}}
    state = "OK" if status == "Primary" else "CRIT"
    return {"changed": False,
            "msg": "WSREP cluster status: %s" % status,
            "data": {"state": state, "metrics": {}}}


def _to_int(val):
    if val == None or val == "":
        return 0
    s = str(val)
    if s.isdigit():
        return int(s)
    # try stripping non-digits
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    digits = ""
    for ch in s:
        if ch.isdigit():
            digits += ch
        else:
            break
    if digits == "":
        return 0
    return int(digits) if not neg else -1 * int(digits)


def _worse(state, new_state):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(state, 0) >= order.get(new_state, 0):
        return state
    return new_state


def _grade_upper(value, levels, current_state):
    # levels is (warn, crit) tuple/list
    if len(levels) < 2:
        return current_state
    warn = levels[0]
    crit = levels[1]
    s = current_state
    if value >= crit:
        s = _worse(s, "CRIT")
    elif value >= warn:
        s = _worse(s, "WARN")
    return s