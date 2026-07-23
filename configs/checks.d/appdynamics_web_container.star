METRIC_MAP = {
    "Error Count": "error_count",
    "Request Count": "request_count",
    "Busy Threads": "busy_threads",
    "Current Threads In Pool": "current_threads",
    "Maximum Threads": "max_threads",
}

def _url_enc(s):
    return s.replace("%", "%25").replace(" ", "%20").replace("|", "%7C").replace("/", "%2F").replace("+", "%2B")

def _get_json(ctx, url, auth):
    res = ctx.run(["curl", "-s", "--insecure", "-u", auth, url], mutates=False)
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if not out:
        return None
    return json.decode(out)

def _get_metric_val(entry):
    vals = entry.get("metricValues", [])
    if len(vals) == 0:
        return None
    v = vals[0]
    if "current" in v:
        return v["current"]
    if "value" in v:
        return v["value"]
    return None

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8090)
    use_ssl = params.get("ssl", False)
    application = params.get("application", "")
    username = params.get("username", "")
    password = params.get("password", "")

    scheme = "https" if use_ssl else "http"
    base = "%s://%s:%s/controller/rest/applications/%s" % (scheme, host, str(port), _url_enc(application))
    auth = username + ":" + password

    if params.get("_discover"):
        tiers_data = _get_json(ctx, base + "/tiers?output=JSON", auth)
        if tiers_data == None or type(tiers_data) != "list":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        discovery = []
        for tier in tiers_data:
            tier_name = tier.get("name", "")
            if not tier_name:
                continue
            nodes_data = _get_json(ctx, base + "/tiers/" + _url_enc(tier_name) + "/nodes?output=JSON", auth)
            if nodes_data == None or type(nodes_data) != "list":
                continue
            for node in nodes_data:
                node_name = node.get("name", "")
                if not node_name:
                    continue
                wc_path = "Application Infrastructure Performance|%s|Individual Nodes|%s|Web Container" % (tier_name, node_name)
                m_data = _get_json(ctx, base + "/metrics?metric-path=" + _url_enc(wc_path) + "&output=JSON", auth)
                if m_data == None or type(m_data) != "list":
                    continue
                for connector_entry in m_data:
                    connector = connector_entry.get("name", "")
                    if not connector:
                        continue
                    item = node_name + " " + connector
                    discovery.append({
                        "item": item,
                        "params": {"tier": tier_name, "levels": None},
                        "metrics": ["error_count", "request_count", "busy_threads", "current_threads", "max_threads"],
                    })

        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    tier = params.get("tier", "")
    levels = params.get("levels", None)

    item_parts = item.split(" ", 1)
    node = item_parts[0] if len(item_parts) >= 1 else item
    connector = item_parts[1] if len(item_parts) >= 2 else ""

    if not tier:
        return {"changed": False, "msg": "tier param required for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    wc_path = "Application Infrastructure Performance|%s|Individual Nodes|%s|Web Container|%s|*" % (tier, node, connector)
    url = (base + "/metric-data?metric-path=" + _url_enc(wc_path) +
           "&time-range-type=BEFORE_NOW&duration-in-mins=1&rollup=true&output=JSON")

    data = _get_json(ctx, url, auth)
    if data == None or type(data) != "list":
        return {"changed": False, "msg": "no data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = {}
    for entry in data:
        m_path = entry.get("metricPath", "")
        segs = m_path.split("|")
        m_name = segs[-1] if len(segs) > 0 else ""
        val = _get_metric_val(entry)
        if val != None:
            values[m_name] = val

    if not values:
        return {"changed": False, "msg": "no metrics for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    current_threads = values.get("Current Threads In Pool", None)
    busy_threads = values.get("Busy Threads", None)
    max_threads = values.get("Maximum Threads", None)
    error_count = values.get("Error Count", None)
    request_count = values.get("Request Count", None)

    state = "OK"
    summary_parts = []
    metrics = {}

    if current_threads != None:
        ct_val = int(current_threads)
        metrics["current_threads"] = ct_val
        if levels != None:
            warn = levels[0]
            crit = levels[1]
            if ct_val >= crit:
                state = "CRIT"
            elif ct_val >= warn:
                state = "WARN"
        summary_parts.append("Current threads: %d" % ct_val)
        if max_threads != None:
            mt_val = int(max_threads)
            metrics["max_threads"] = mt_val
            if mt_val > 0:
                pct = 100 * ct_val // mt_val
                summary_parts.append("%d%% of %d" % (pct, mt_val))

    if busy_threads != None:
        bt_val = int(busy_threads)
        metrics["busy_threads"] = bt_val
        summary_parts.append("Busy threads: %d" % bt_val)

    if error_count != None:
        ec_val = int(error_count)
        metrics["error_count"] = ec_val
        summary_parts.append("Errors: %d/min" % ec_val)

    if request_count != None:
        rc_val = int(request_count)
        metrics["request_count"] = rc_val
        summary_parts.append("Requests: %d/min" % rc_val)

    msg = ", ".join(summary_parts) if summary_parts else item
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}