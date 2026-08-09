# Translated Checkmk check: msexch_dag_contentindex
# Reproduces discovery + check logic for "Exchange DAG ContentIndex of %s".

DEPRECATED_CONTENTINDEX_MESSAGE = "ContentIndex no longer available in recent Exchange versions. You can safely delete this Service."


def parse_msexch_dag_output(stdout):
    """Parse the colon-separated 'key : value' block output into
    a dict of dbname -> {field: value}. Mirrors parse_msexch_dag."""
    collected_databases = {}
    current_record = {}
    lines = stdout.splitlines()
    start_key = None
    for line in lines:
        if ":" not in line:
            continue
        parts = line.split(":", 1)
        key = parts[0].strip()
        val = parts[1].strip()
        if start_key == None:
            start_key = key
        if key == start_key:
            current_record = {}
        if key == "DatabaseName":
            collected_databases[val] = current_record
        else:
            current_record[key] = val
    return collected_databases


def discover_items(section):
    items = []
    for dbname, db in section.items():
        ci = db.get("ContentIndexState")
        if ci == None or ci == "NotApplicable":
            continue
        items.append({"item": dbname, "metrics": []})
    return items


def main(ctx, params):
    if params.get("_discover"):
        # Probe for Exchange-related artifacts. The real data here would
        # come from a Checkmk Windows agent section, but since we run on
        # the yolo-man host (Linux), we look for any on-host evidence this
        # product/feature is present.
        res = ctx.run(["which", "Get-MailboxDatabaseCopyStatus"], mutates=False)
        # which returns rc 0 if found; 127 means not present.
        if res.rc == 127:
            return {"changed": False, "msg": "no Exchange DAG data available",
                    "data": {"discovery": []}}

        # If we do have an Exchange data source, parse it.
        out = res.stdout
        section = parse_msexch_dag_output(out)
        if not section:
            return {"changed": False, "msg": "no Exchange DAG databases found",
                    "data": {"discovery": []}}
        items = discover_items(section)
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")

    # In check mode we still need the source data. Re-probe the same way.
    res = ctx.run(["which", "Get-MailboxDatabaseCopyStatus"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "no Exchange DAG data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = parse_msexch_dag_output(res.stdout)
    db = section.get(item)
    if db == None:
        return {"changed": False, "msg": "no such database: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val = db.get("ContentIndexState")
    if val == None:
        return {"changed": False, "msg": "ContentIndexState not available for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if val == "NotApplicable":
        return {"changed": False, "msg": DEPRECATED_CONTENTINDEX_MESSAGE,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    state = "OK" if val == "Healthy" else "WARN"
    return {"changed": False, "msg": "Status: %s" % val,
            "data": {"state": state, "metrics": {}, "details": ""}}