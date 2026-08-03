DEFAULT_ITEM_NAME = "default"

def _to_bytes(value, uom):
    uom = uom.lower()
    if uom == "kbytes":
        return int(value * 1024)
    if uom == "mbytes":
        return int(value * 1024 * 1024)
    if uom == "gbytes":
        return int(value * 1024 * 1024 * 1024)
    if uom == "bytes":
        return int(value)
    return 0

def _parse_queue_output(lines):
    result = {}
    instance_name = DEFAULT_ITEM_NAME
    for line in lines:
        parts = line.split()
        if not parts:
            continue
        if parts[0].startswith("[[[") and parts[0].endswith("]]]"):
            instance_name = parts[0][3:-3] or DEFAULT_ITEM_NAME
            continue
        mq = {"name": None, "size": 0, "length": 0}
        if parts[0].startswith("QUEUE_"):
            if len(parts) == 2:
                mq["size"] = 0
                mq["length"] = int(parts[1])
            else:
                mq["size"] = int(parts[1])
                mq["length"] = int(parts[2])
            mq["name"] = parts[0].split("_")[1]
        elif len(parts) >= 2 and parts[-2] + " " + parts[-1] == "is empty":
            mq["name"] = "empty"
            mq["size"] = 0
            mq["length"] = 0
        elif parts[0] == "--" or (len(parts) >= 2 and parts[0] == "Total" and parts[1] == "requests:"):
            if parts[0] == "--":
                mq["size"] = _to_bytes(float(parts[1]), parts[2])
                mq["length"] = int(parts[4])
            else:
                mq["size"] = 0
                mq["length"] = int(parts[2])
            mq["name"] = "mail"
        if mq["name"] != None:
            result.setdefault(instance_name, []).append(mq)
    return result

def _find_postqueue(ctx):
    res = ctx.run(["which", "postqueue"], mutates=False)
    if res.rc == 0:
        return res.stdout.strip()
    res = ctx.run(["postqueue", "-v"], mutates=False)
    if res.rc == 0:
        return "postqueue"
    return None

def _queue_data(ctx):
    pq = _find_postqueue(ctx)
    if pq == None:
        return None
    res = ctx.run([pq, "-p"], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.splitlines()

def _grade(value, warn, crit):
    if warn == None or crit == None:
        return "OK"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _resolve_levels(params):
    deferred_params = params.get("levels", None)
    if type(deferred_params) == "list" and len(deferred_params) == 2:
        deferred_warn = deferred_params[0]
        deferred_crit = deferred_params[1]
    elif type(deferred_params) == "dict":
        deferred_warn = deferred_params.get("warn", 10)
        deferred_crit = deferred_params.get("crit", 20)
    else:
        deferred_warn = params.get("warn", 10)
        deferred_crit = params.get("crit", 20)

    active_params = params.get("active_levels", None)
    if type(active_params) == "list" and len(active_params) == 2:
        active_warn = active_params[0]
        active_crit = active_params[1]
    elif type(active_params) == "dict":
        active_warn = active_params.get("warn", 200)
        active_crit = active_params.get("crit", 300)
    else:
        active_warn = params.get("active_warn", 200)
        active_crit = params.get("active_crit", 300)
    return deferred_warn, deferred_crit, active_warn, active_crit

def main(ctx, params):
    if params.get("_discover"):
        lines = _queue_data(ctx)
        if lines == None:
            return {"changed": False, "msg": "no postfix mailqueue found", "data": {"discovery": []}}
        section = _parse_queue_output(lines)
        out = []
        for instance in section:
            out.append({"item": instance, "params": {"warn": 10, "crit": 20}, "metrics": ["length", "size"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    if item == None:
        item = DEFAULT_ITEM_NAME
    lines = _queue_data(ctx)
    if lines == None:
        return {"changed": False, "msg": "no postfix mailqueue found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_queue_output(lines)
    if item not in section:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    deferred_warn, deferred_crit, active_warn, active_crit = _resolve_levels(params)

    worst_state = "OK"
    metrics = {}
    details_lines = []

    for mq in section[item]:
        qname = mq["name"] if mq["name"] else ""
        if qname == "active":
            warn = active_warn
            crit = active_crit
        elif qname == "mail":
            warn = deferred_warn
            crit = deferred_crit
        else:
            warn = deferred_warn
            crit = deferred_crit

        length_metric = "mail_queue_active_length" if qname == "active" else "length"
        size_metric = "mail_queue_active_size" if qname == "active" else "size"

        lstate = _grade(mq["length"], warn, crit)
        if lstate == "CRIT" and worst_state != "CRIT":
            worst_state = "CRIT"
        elif lstate == "WARN" and worst_state == "OK":
            worst_state = "WARN"

        metrics[length_metric] = mq["length"]
        metrics[size_metric] = mq["size"]
        details_lines.append("%s queue length=%d size=%d" % (qname, mq["length"], mq["size"]))

    details = "\n".join(details_lines)
    msg = "Postfix Queue %s: %s" % (item, details)
    return {"changed": False, "msg": msg, "data": {"state": worst_state, "metrics": metrics, "details": details}}