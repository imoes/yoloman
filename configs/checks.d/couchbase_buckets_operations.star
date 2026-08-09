# Couchbase bucket operations check for Checkmk -> Starlark translation.
# Monitors per-bucket and total Couchbase operations via the Couchbase REST API.

# Default thresholds (Checkmk default params are empty, meaning no levels).
DEFAULT_OPS_WARN = None
DEFAULT_OPS_CRIT = None

# Operation keys we extract from each bucket's JSON data.
OP_KEYS = ["ops", "cmd_get", "cmd_set", "ep_ops_create", "ep_ops_update", "ep_num_ops_del_meta"]

# Human-readable labels for each operation type.
OP_LABELS = {
    "ops": "Total (per server)",
    "cmd_get": "Gets",
    "cmd_set": "Sets",
    "ep_ops_create": "Creates",
    "ep_ops_update": "Updates",
    "ep_num_ops_del_meta": "Deletes",
}


def _get_buckets_data(ctx, params):
    """Fetch bucket stats JSON from the Couchbase REST API. Returns list of dicts or None if unavailable."""
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    username = params.get("username", "Administrator")
    password = params.get("password", "password")
    url = "http://%s:%s/pools/default/buckets" % (host, port)

    # Probe: is Couchbase running? Use a lightweight endpoint.
    probe = ctx.run(["curl", "-s", "-m", "10", "-u", "%s:%s" % (username, password), url], mutates=False)
    if probe.rc != 0 or not probe.stdout:
        return None

    # The buckets listing is an array of JSON objects.
    buckets = json.decode(probe.stdout)
    if len(buckets) == 0:
        return None

    rows = []
    for b in buckets:
        name = b.get("name")
        # Each bucket has a "uri" with its detailed stats path.
        bucket_uri = b.get("uri")
        if name == None or bucket_uri == None:
            continue
        stats_url = "http://%s:%s%s" % (host, port, bucket_uri)
        res = ctx.run(["curl", "-s", "-m", "10", "-u", "%s:%s" % (username, password), stats_url], mutates=False)
        if res.rc != 0 or not res.stdout:
            continue
        data = json.decode(res.stdout)
        data["name"] = name
        rows.append(data)
    if len(rows) == 0:
        return None
    return rows


def _extract_stats(data):
    """Extract operation counters from a bucket's stats JSON. Returns dict of key->value."""
    out = {}
    # Couchbase returns stats in a nested structure. The basic stats are often
    # at the top level under keys like "ops", "cmd_get", etc.
    for k in OP_KEYS:
        v = data.get(k)
        if v != None:
            out[k] = v
    # Some Couchbase versions nest under "op" with "samples". Handle the
    # common flat case primarily, but also try one level of nesting.
    return out


def _grade_value(value, warn, crit):
    """Grade a numeric value against warn/crit levels. Returns (state, hr)."""
    state = "OK"
    if warn != None and crit != None:
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    hr = "%f/s" % value
    return state, hr


def _check_ops_data(ctx, data, params, item_label):
    """Reproduce _check_ops_data: check levels on ops, with perfdata."""
    metrics = {}
    details_parts = []
    overall_state = "OK"

    ops_levels = params.get("ops")  # Checkmk check_default_parameters is {}
    # check_levels legacy: params.get("ops") could be (warn, crit) tuple or dict.
    warn = None
    crit = None
    if ops_levels != None:
        if type(ops_levels) == "list":
            warn = ops_levels[0] if len(ops_levels) > 0 else None
            crit = ops_levels[1] if len(ops_levels) > 1 else None
        elif type(ops_levels) == "dict":
            warn = ops_levels.get("warn")
            crit = ops_levels.get("crit")

    # The "ops" key is the only one with levels by default (check_levels for "op_s").
    ops_val = data.get("ops")
    if ops_val != None:
        state, hr = _grade_value(ops_val, warn, crit)
        if state != "OK":
            overall_state = state
        metrics["ops"] = ops_val
        details_parts.append("Total (per server): %s" % hr)

    # The other keys have no levels (None) — just report as info.
    for k in OP_KEYS[1:]:
        v = data.get(k)
        if v != None:
            metrics[k] = v
            label = OP_LABELS.get(k, k)
            hr = "%f/s" % v
            details_parts.append("%s: %s" % (label, hr))

    msg = item_label + ": " + ", ".join(details_parts) if len(details_parts) > 0 else item_label + ": no operations data"
    details = "\n".join(details_parts)
    return {"state": overall_state, "metrics": metrics, "msg": msg, "details": details}


def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        data = _get_buckets_data(ctx, params)
        if data == None:
            # Couchbase not present -> empty discovery (no placeholder).
            return {"changed": False, "msg": "Couchbase not reachable", "data": {"discovery": []}}

        discovery = []
        for row in data:
            name = row.get("name")
            if name == None:
                continue
            stats = _extract_stats(row)
            if "ops" in stats:
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": [k for k in OP_KEYS if k in stats],
                })
        return {"changed": False, "msg": "discovered %d buckets" % len(discovery), "data": {"discovery": discovery}}

    # --- CHECK MODE (per-bucket) ---
    item = params.get("item", "")
    data = _get_buckets_data(ctx, params)
    if data == None:
        return {"changed": False, "msg": "Couchbase not reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the item's bucket data.
    target = None
    for row in data:
        if row.get("name") == item:
            target = row
            break
    if target == None:
        return {"changed": False, "msg": "bucket not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = _extract_stats(target)
    if "ops" not in stats:
        return {"changed": False, "msg": item + ": no operations data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    result = _check_ops_data(ctx, stats, params, item)
    return {"changed": False, "msg": result["msg"], "data": {"state": result["state"], "metrics": result["metrics"], "details": result["details"]}}