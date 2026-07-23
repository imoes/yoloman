_SERVICES_QUERY = "SELECT PORT, SERVICE_NAME, PROCESS_ID, IFNULL(DETAIL,''), ACTIVE_STATUS, IFNULL(TO_INTEGER(SQL_PORT),0), COORDINATOR_TYPE FROM SYS.M_SERVICES"

def _parse_hdbsql_row(line):
    line = line.strip()
    if len(line) < 2 or not line.startswith('"') or not line.endswith('"'):
        return []
    return line[1:-1].split('","')

def _make_hdbsql_cmd(sid, userstore_key, user, password, instance, query):
    sid_lower = sid.lower()
    if userstore_key != None:
        inner = "hdbsql -x -a -U %s \"%s\"" % (userstore_key, query)
    else:
        inner = "hdbsql -x -a -n localhost -i %s -u %s -p %s \"%s\"" % (instance, user, password, query)
    return ["su", "-", sid_lower + "adm", "-c", inner]

def _query_services(ctx, sid, instance, userstore_key, user, password):
    cmd = _make_hdbsql_cmd(sid, userstore_key, user, password, instance, _SERVICES_QUERY)
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return None, res.stderr.strip()
    rows = []
    for line in res.stdout.splitlines():
        parts = _parse_hdbsql_row(line)
        if len(parts) >= 7:
            rows.append(parts)
    return rows, ""

def _find_hana_instances(ctx):
    instances = []
    if not ctx.file_exists("/usr/sap"):
        return instances
    res = ctx.run(["find", "/usr/sap", "-maxdepth", "2", "-name", "HDB*", "-type", "d"], mutates=False)
    if res.rc != 0:
        return instances
    seen = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split("/")
        if len(parts) >= 5:
            s = parts[3]
            hdb = parts[4]
            if hdb.startswith("HDB") and len(hdb) > 3:
                num = hdb[3:]
                if num.isdigit():
                    key = s + ":" + num
                    if key not in seen:
                        seen[key] = True
                        instances.append({"sid": s, "instance": num})
    return instances

def main(ctx, params):
    sid = params.get("sid", "")
    instance = params.get("instance", "00")
    userstore_key = params.get("userstore_key", None)
    user = params.get("user", "SYSTEM")
    password = params.get("password", "")

    if params.get("_discover"):
        all_inst = [{"sid": sid, "instance": instance}] if sid else _find_hana_instances(ctx)
        discovered = []
        for entry in all_inst:
            s = entry["sid"]
            i = entry["instance"]
            rows, _ = _query_services(ctx, s, i, userstore_key, user, password)
            if rows == None:
                continue
            for row in rows:
                svc_name = row[1]
                coordin = row[6]
                item_name = "%s:%s - %s" % (s, i, svc_name)
                discovered.append({
                    "item": item_name,
                    "params": {"coordin": coordin, "sid": s, "instance": i},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d services" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode
    item = params.get("item", "")
    coordin_expected = params.get("coordin", "")

    check_sid = sid
    check_instance = instance
    check_svc = item

    if " - " in item:
        split_parts = item.split(" - ", 1)
        prefix = split_parts[0]
        check_svc = split_parts[1]
        if ":" in prefix and not check_sid:
            sid_parts = prefix.split(":", 1)
            check_sid = sid_parts[0]
            check_instance = sid_parts[1]

    if not check_sid:
        return {
            "changed": False,
            "msg": "sid not configured",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows, err = _query_services(ctx, check_sid, check_instance, userstore_key, user, password)
    if rows == None:
        return {
            "changed": False,
            "msg": "Login into database failed: " + err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": err},
        }

    found = None
    for row in rows:
        if row[1] == check_svc:
            found = row
            break

    if found == None:
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    port = found[0]
    pid = found[2]
    acting_raw = found[4].strip().lower()
    sql_port_str = found[5].strip()
    coordin = found[6].strip()

    acting = "yes" if (acting_raw == "yes" or acting_raw == "true" or acting_raw == "1") else "no"

    sql_port = 0
    if sql_port_str.isdigit():
        sql_port = int(sql_port_str)

    summaries = ["Port: %s, PID: %s" % (port, pid)]
    state = "OK"

    if coordin_expected and coordin_expected != coordin:
        state = "WARN"
        summaries.append("Role: changed from %s to %s" % (coordin_expected, coordin))
    elif coordin.lower() != "none":
        summaries.append("Role: %s" % coordin)

    if sql_port:
        summaries.append("SQL-Port: %s" % sql_port)

    if acting != "yes":
        state = "CRIT"
        summaries.append("not acting")

    metrics = {}
    if sql_port:
        metrics["sql_port"] = sql_port

    return {
        "changed": False,
        "msg": ", ".join(summaries),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }