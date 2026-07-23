def _bytes_to_gib(b):
    if b <= 0:
        return 0.0
    return float(b) / (1024.0 * 1024.0 * 1024.0)

def _pct(used, total):
    if total <= 0:
        return 0.0
    return float(used) / float(total) * 100.0

def _threshold_state(pct, warn, crit):
    if pct >= float(crit):
        return "CRIT"
    if pct >= float(warn):
        return "WARN"
    return "OK"

def _worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    return a if order.get(a, 0) >= order.get(b, 0) else b

def _get_token(ctx, host, user, password):
    body = "grant_type=password&username=" + user + "&password=" + password
    res = ctx.run([
        "curl", "-sk", "-X", "POST",
        "-H", "Content-Type: application/x-www-form-urlencoded",
        "--data-raw", body,
        "https://" + host + "/rest/oauth",
    ], mutates=False)
    if res.rc != 0:
        return ""
    if not res.stdout:
        return ""
    d = json.decode(res.stdout)
    return d.get("access_token", "")

def _api_get(ctx, host, token, path):
    return ctx.run([
        "curl", "-sk",
        "-H", "Authorization: Bearer " + token,
        "-H", "Accept: application/json",
        "https://" + host + path,
    ], mutates=False)

def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "admin")
    password = params.get("password", "")
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)

    token = _get_token(ctx, host, user, password)
    if token == "":
        return {
            "changed": False,
            "msg": "Cannot authenticate to StoreOnce at " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    fed_res = _api_get(ctx, host, token, "/rest/federated/v1/appliances")
    if fed_res.rc != 0 or not fed_res.stdout:
        return {
            "changed": False,
            "msg": "Cannot get federation data from " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    fed_data = json.decode(fed_res.stdout)
    members = fed_data.get("members", [])

    if params.get("_discover"):
        disc = []
        for m in members:
            hn = m.get("hostname", "")
            if hn:
                disc.append({
                    "item": hn,
                    "params": {"warn": 80.0, "crit": 90.0},
                    "metrics": [
                        "local_used_pct", "cloud_used_pct", "combined_used_pct",
                        "local_used_gib", "local_capacity_gib",
                        "cloud_used_gib", "cloud_capacity_gib",
                        "combined_used_gib", "combined_capacity_gib",
                        "dedupe_ratio",
                    ],
                })
        return {
            "changed": False,
            "msg": "discovered %d appliances" % len(disc),
            "data": {"discovery": disc},
        }

    item = params.get("item", "")

    member = None
    for m in members:
        if m.get("hostname", "") == item:
            member = m
            break

    if member == None:
        return {
            "changed": False,
            "msg": "Appliance not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Dashboard may live on the member's own address; try there first, fall back to primary
    member_addr = member.get("address", "")
    if not member_addr:
        member_addr = host

    dash_token = token
    if member_addr != host:
        t = _get_token(ctx, member_addr, user, password)
        if t != "":
            dash_token = t
        else:
            member_addr = host

    dash_res = _api_get(ctx, member_addr, dash_token, "/rest/appliances/dashboard")
    if dash_res.rc != 0 or not dash_res.stdout:
        return {
            "changed": False,
            "msg": "Cannot get dashboard data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    dash = json.decode(dash_res.stdout)

    local_cap = int(dash.get("localCapacityBytes", 0))
    local_free = int(dash.get("localFreeBytes", 0))
    cloud_cap = int(dash.get("cloudCapacityBytes", 0))
    cloud_free = int(dash.get("cloudFreeBytes", 0))
    dedupe = float(dash.get("dedupeRatio", 0.0))

    local_used = local_cap - local_free
    cloud_used = cloud_cap - cloud_free
    combined_cap = local_cap + cloud_cap
    combined_free = local_free + cloud_free
    combined_used = combined_cap - combined_free

    local_pct = _pct(local_used, local_cap)
    cloud_pct = _pct(cloud_used, cloud_cap)
    combined_pct = _pct(combined_used, combined_cap)

    local_st = _threshold_state(local_pct, warn, crit) if local_cap > 0 else "OK"
    cloud_st = _threshold_state(cloud_pct, warn, crit) if cloud_cap > 0 else "OK"
    overall = _worst(local_st, cloud_st)

    parts = []
    if local_cap > 0:
        parts.append("Local: %f/%f GiB (%f%%)" % (
            _bytes_to_gib(local_used), _bytes_to_gib(local_cap), local_pct))
    if cloud_cap > 0:
        parts.append("Cloud: %f/%f GiB (%f%%)" % (
            _bytes_to_gib(cloud_used), _bytes_to_gib(cloud_cap), cloud_pct))
    if combined_cap > 0:
        parts.append("Combined: %f/%f GiB (%f%%)" % (
            _bytes_to_gib(combined_used), _bytes_to_gib(combined_cap), combined_pct))
    if dedupe > 0.0:
        parts.append("Dedup: %f:1" % dedupe)

    msg = ", ".join(parts) if parts else "No storage data for " + item

    metrics = {}
    if local_cap > 0:
        metrics["local_used_pct"] = local_pct
        metrics["local_used_gib"] = _bytes_to_gib(local_used)
        metrics["local_capacity_gib"] = _bytes_to_gib(local_cap)
    if cloud_cap > 0:
        metrics["cloud_used_pct"] = cloud_pct
        metrics["cloud_used_gib"] = _bytes_to_gib(cloud_used)
        metrics["cloud_capacity_gib"] = _bytes_to_gib(cloud_cap)
    if combined_cap > 0:
        metrics["combined_used_pct"] = combined_pct
        metrics["combined_used_gib"] = _bytes_to_gib(combined_used)
        metrics["combined_capacity_gib"] = _bytes_to_gib(combined_cap)
    if dedupe > 0.0:
        metrics["dedupe_ratio"] = dedupe

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": overall, "metrics": metrics, "details": ""},
    }