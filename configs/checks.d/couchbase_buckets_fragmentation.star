# Helper to parse JSON lines into a dict of bucket_name -> bucket_data
def _parse_couchbase_fragmentation(ctx):
    res = ctx.run(["cbq", "-u", "", "-p", "", "--silent", "-q",
                   "SELECT name, couch_docs_fragmentation, couch_views_fragmentation FROM system:bucket"], 
                  mutates=False)
    if res.rc != 0:
        return {}
    section = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Guard instead of try/except: check JSON validity by checking structure
        if line.startswith("{") and line.endswith("}"):
            data = json.decode(line)
            if type(data) == "dict" and "name" in data:
                section[data["name"]] = data
    return section


def main(ctx, params):
    if params.get("_discover"):
        section = _parse_couchbase_fragmentation(ctx)
        out = []
        for item, data in section.items():
            if "couch_docs_fragmentation" in data or "couch_views_fragmentation" in data:
                out.append({
                    "item": item,
                    "params": {},
                    "metrics": ["docs_fragmentation", "views_fragmentation"]
                })
        return {
            "changed": False,
            "msg": "discovered %d buckets" % len(out),
            "data": {"discovery": out}
        }

    item = params.get("item", "")
    section = _parse_couchbase_fragmentation(ctx)
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "bucket not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    docs_frag = data.get("couch_docs_fragmentation")
    views_frag = data.get("couch_views_fragmentation")
    
    state = "OK"
    msg_parts = []
    metrics = {}
    
    # Check docs fragmentation
    if docs_frag != None and (type(docs_frag) == "int" or type(docs_frag) == "float"):
        # Checkmk defaults: no levels -> OK; if present, use warn/crit
        docs_warn = params.get("docs", (80, 90))  # fallback to tuple (warn, crit)
        docs_warn_val = docs_warn[0] if (type(docs_warn) == "list" or type(docs_warn) == "tuple") else 80
        docs_crit_val = docs_warn[1] if (type(docs_warn) == "list" or type(docs_warn) == "tuple") else 90
        
        if docs_frag >= docs_crit_val:
            state = "CRIT"
        elif docs_frag >= docs_warn_val and state != "CRIT":
            state = "WARN"
        msg_parts.append("Documents fragmentation: %d%%" % docs_frag)
        metrics["docs_fragmentation"] = docs_frag
    
    # Check views fragmentation
    if views_frag != None and (type(views_frag) == "int" or type(views_frag) == "float"):
        # Checkmk defaults: no levels -> OK; if present, use warn/crit
        views_warn = params.get("views", (80, 90))  # fallback to tuple (warn, crit)
        views_warn_val = views_warn[0] if (type(views_warn) == "list" or type(views_warn) == "tuple") else 80
        views_crit_val = views_warn[1] if (type(views_warn) == "list" or type(views_warn) == "tuple") else 90
        
        if views_frag >= views_crit_val:
            state = "CRIT"
        elif views_frag >= views_warn_val and state != "CRIT":
            state = "WARN"
        msg_parts.append("Views fragmentation: %d%%" % views_frag)
        metrics["views_fragmentation"] = views_frag
    
    if state == "OK" and not msg_parts:
        msg_parts.append("No fragmentation data available")
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": ""}
    }