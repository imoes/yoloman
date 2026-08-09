# MySQL InnoDB IO check plugin (read-only Starlark translation)
#
# Discovers MySQL instances and reports InnoDB read/write bandwidth.
# Data source: MySQL server itself (mysql CLI).

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _worse(current, new):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if rank.get(new, 0) > rank.get(current, 0):
        return new
    return current

def _verdict(state, msg, metrics):
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }

def _ok(msg, metrics):
    return _verdict("OK", msg, metrics)

def _warn(msg, metrics):
    return _verdict("WARN", msg, metrics)

def _crit(msg, metrics):
    return _verdict("CRIT", msg, metrics)

def _unknown(msg):
    return _verdict("UNKNOWN", msg, {})

# ---------------------------------------------------------------------------
# MySQL data gathering
# ---------------------------------------------------------------------------

# Returns: (instances, err) where each instance is {"item": name,
# "counters": {...}}. `err` == None on success.
def _gather_mysql(ctx):
    mysql = ctx.run(["mysql", "--version"], mutates=False)
    if mysql.rc == 127:
        return ([], "mysql not installed")
    if mysql.rc != 0:
        return ([], "mysql --version failed rc=%d: %s" % (mysql.rc, mysql.stderr))

    query_read = "SHOW GLOBAL STATUS LIKE 'Innodb_data_read'"
    query_written = "SHOW GLOBAL STATUS LIKE 'Innodb_data_written'"
    read_res = ctx.run(
        ["mysql", "--batch", "--raw", "--skip-column-names", "-e", query_read],
        mutates=False,
    )
    written_res = ctx.run(
        ["mysql", "--batch", "--raw", "--skip-column-names", "-e", query_written],
        mutates=False,
    )
    if read_res.rc != 0:
        return ([], "mysql query failed rc=%d: %s" % (read_res.rc, read_res.stderr))
    if written_res.rc != 0:
        return ([], "mysql query failed rc=%d: %s" % (written_res.rc, written_res.stderr))

    read_s = read_res.stdout.strip().split("\t")
    written_s = written_res.stdout.strip().split("\t")

    read_v = int(read_s[1]) if len(read_s) > 1 and read_s[1].isdigit() else 0
    written_v = int(written_s[1]) if len(written_s) > 1 and written_s[1].isdigit() else 0

    hostname = ctx.facts().get("hostname", "localhost")
    return ([{
        "item": hostname,
        "counters": {
            "Innodb_data_read": read_v,
            "Innodb_data_written": written_v,
        },
    }], None)

# ---------------------------------------------------------------------------
# Rate computation (stateful across runs via a local dict; best-effort)
# ---------------------------------------------------------------------------

def _rate(ctx, store, key, now, value):
    prev = store.get(key)
    if prev == None:
        store[key] = {"t": now, "v": value}
        return 0.0
    dt = now - prev["t"]
    if dt <= 0:
        store[key] = {"t": now, "v": value}
        return 0.0
    rate_val = float(value - prev["v"]) / dt
    store[key] = {"t": now, "v": value}
    return rate_val

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(ctx, params):
    if params.get("_discover"):
        instances, err = _gather_mysql(ctx)
        if err != None or len(instances) == 0:
            return {
                "changed": False,
                "msg": "discovered 0 MySQL instances",
                "data": {"discovery": []},
            }
        discovery = []
        for inst in instances:
            if not (("Innodb_data_read" in inst["counters"]) and
                    ("Innodb_data_written" in inst["counters"])):
                continue
            discovery.append({
                "item": inst["item"],
                "params": {"read_bytes": None, "write_bytes": None, "average": 0},
                "metrics": ["read", "read.avg", "write", "write.avg"],
            })
        return {
            "changed": False,
            "msg": "discovered %d MySQL instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- check mode for one item ---
    item = params.get("item", "")
    instances, err = _gather_mysql(ctx)
    if err != None:
        return _unknown(err)

    data = None
    for inst in instances:
        if inst["item"] == item or item == "":
            data = inst["counters"]
            break
    if data == None:
        return _unknown("no MySQL instance matches item: %s" % item)

    read_v = data.get("Innodb_data_read", 0)
    written_v = data.get("Innodb_data_written", 0)

    warn_r = params.get("read_bytes")
    crit_r = None
    if type(warn_r) == "list":
        crit_r = warn_r[1] if len(warn_r) > 1 else None
        warn_r = warn_r[0] if len(warn_r) > 0 else None
    warn_w = params.get("write_bytes")
    crit_w = None
    if type(warn_w) == "list":
        crit_w = warn_w[1] if len(warn_w) > 1 else None
        warn_w = warn_w[0] if len(warn_w) > 0 else None

    now = 0.0
    dres = ctx.run(["date", "+%s"], mutates=False)
    if dres.rc == 0:
        now = float(dres.stdout.strip())
    else:
        st = ctx.stat("/proc/uptime")
        if st != None and st.get("exists"):
            now = float(st.get("size", 0))

    store = {}
    read_rate = _rate(ctx, store, "mysql.read", now, read_v)
    write_rate = _rate(ctx, store, "mysql.write", now, written_v)

    metrics = {"read": read_rate, "write": write_rate}

    state = "OK"
    msg_parts = []

    if warn_r != None:
        if crit_r != None and read_rate >= crit_r:
            state = _worse(state, "CRIT")
        elif read_rate >= warn_r:
            state = _worse(state, "WARN")
    msg_parts.append("Read: %d B/s" % int(read_rate))

    if warn_w != None:
        if crit_w != None and write_rate >= crit_w:
            state = _worse(state, "CRIT")
        elif write_rate >= warn_w:
            state = _worse(state, "WARN")
    msg_parts.append("Written: %d B/s" % int(write_rate))

    msg = "; ".join(msg_parts)
    if state == "OK":
        return _ok(msg, metrics)
    if state == "WARN":
        return _warn(msg, metrics)
    return _crit(msg, metrics)