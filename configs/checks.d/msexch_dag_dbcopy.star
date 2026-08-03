# ===== translated check: msexch_dag_dbcopy =====

def _parse_dag_section(text):
    collected = {}
    current = {}
    lines = text.splitlines()
    if not lines:
        return collected
    start_key = lines[0].split(":", 1)[0].strip()
    for line in lines:
        if ":" not in line:
            continue
        key = line.split(":", 1)[0].strip()
        val = line.split(":", 1)[1].strip()
        if key == start_key:
            current = {}
        if key == "DatabaseName":
            collected[val] = current
        else:
            current[key] = val
    return collected


def _gather_dag_data(ctx):
    res = ctx.run(
        [
            "exch", "dag", "dbcopy", "-format", "keyvalue",
        ],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    if not res.stdout.strip():
        return None
    return _parse_dag_section(res.stdout)


def main(ctx, params):
    if params.get("_discover"):
        section = _gather_dag_data(ctx)
        if section == None:
            return {
                "changed": False,
                "msg": "no Exchange DAG dbcopy data source found",
                "data": {"discovery": []},
            }
        if not section:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        out = []
        for dbname, db in section.items():
            status = db.get("Status")
            if status == None:
                continue
            out.append({
                "item": dbname,
                "params": {"inv_key": "Status", "inv_val": status},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    section = _gather_dag_data(ctx)
    if section == None:
        return {
            "changed": False,
            "msg": "no Exchange DAG dbcopy data source found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    db = section.get(item)
    if db == None:
        return {
            "changed": False,
            "msg": "no such DAG dbcopy item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    inv_key = params.get("inv_key", "Status")
    inv_val = params.get("inv_val")
    val = db.get(inv_key)
    if val == None:
        return {
            "changed": False,
            "msg": "%s not available for %s" % (inv_key, item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if inv_val != None:
        state = "OK" if val == inv_val else "WARN"
        summary = "%s is %s" % (inv_key, val)
        if state == "WARN":
            summary = "%s changed from %s to %s" % (inv_key, inv_val, val)
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": {}, "details": summary},
        }
    return {
        "changed": False,
        "msg": "%s is %s" % (inv_key, val),
        "data": {"state": "OK", "metrics": {}, "details": "Status is %s" % val},
    }