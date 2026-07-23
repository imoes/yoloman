_SUMMARY_KEYS = [
    ("catStoresSummary", "Cat stores"),
    ("cloudBankStoresSummary", "Cloud bank"),
    ("nasSharesSummary", "NAS Shares"),
    ("vtlLibrariesSummary", "VTL Libraries"),
    ("nasRepMappingSummary", "NAS Replication Mapping"),
    ("vtlRepMappingSummary", "VTL Replication Mapping"),
]

# (statusSummary key, display label, state string, priority)
_STATUS_ITEMS = [
    ("numOk",       "Ok",       "OK",      0),
    ("numWarning",  "Warning",  "WARN",    1),
    ("numCritical", "Critical", "CRIT",    2),
    ("numUnknown",  "Unknown",  "UNKNOWN", 3),
]

_STATE_NAME = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

def _curl_json(ctx, host, path, username, password):
    url = "https://" + host + path
    res = ctx.run([
        "curl", "-sk", "--fail",
        "-u", username + ":" + password,
        "-H", "Accept: application/json",
        url,
    ], mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout.strip():
        return None
    return json.decode(res.stdout)

def main(ctx, params):
    host     = params.get("host",     "localhost")
    username = params.get("username", "admin")
    password = params.get("password", "")

    fed = _curl_json(ctx, host,
                     "/api/v1/management-facilities/federation",
                     username, password)

    if fed == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "no federation data",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "cannot reach StoreOnce API on " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    members = fed.get("members", [])

    if params.get("_discover"):
        discovery = []
        for m in members:
            hostname = m.get("hostname", "")
            if hostname:
                discovery.append({
                    "item":    hostname,
                    "params":  {},
                    "metrics": [],
                })
        return {"changed": False,
                "msg": "discovered %d appliances" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    uuid = ""
    for m in members:
        if m.get("hostname") == item:
            uuid = m.get("uuid", "")
            break

    if not uuid:
        return {"changed": False,
                "msg": "appliance not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dashboard = _curl_json(
        ctx, host,
        "/api/v1/management-facilities/appliances/" + uuid + "/dashboard",
        username, password,
    )
    if dashboard == None:
        return {"changed": False,
                "msg": "no dashboard data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    worst = 0  # 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
    parts = []

    for summary_key, summary_label in _SUMMARY_KEYS:
        summary = dashboard.get(summary_key)
        if summary == None:
            continue
        status = summary.get("statusSummary", {})
        total  = status.get("total", 0)
        for num_key, descr, _state_str, priority in _STATUS_ITEMS:
            count = status.get(num_key, 0)
            if count == 0:
                continue
            parts.append("%s %s (%d of %d)" % (summary_label, descr, count, total))
            if priority > worst:
                worst = priority

    if not parts:
        msg = "All summaries OK"
    else:
        msg = ", ".join(parts)

    return {"changed": False, "msg": msg,
            "data": {"state": _STATE_NAME[worst], "metrics": {}, "details": ""}}