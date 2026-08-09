# BI Datasource Connection check
# Monitors Checkmk BI site connections and aggregation health by querying
# the Checkmk REST API. The target host must be a Checkmk monitoring server.

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {
                        "host": "localhost",
                        "site": "",
                        "user": "automation",
                        "secret": "",
                        "port": 443,
                        "protocol": "https",
                    },
                    "metrics": [],
                },
            ]},
        }

    host     = params.get("host", "localhost")
    site     = params.get("site", "")
    user     = params.get("user", "automation")
    secret   = params.get("secret", "")
    port     = params.get("port", 443)
    protocol = params.get("protocol", "https")

    if not site:
        return {
            "changed": False,
            "msg": "Parameter 'site' is required (Checkmk site name)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    base = "%s://%s:%d/%s/check_mk/api/1.0" % (protocol, host, port, site)
    auth = user + ":" + secret

    missing_sites  = []
    missing_aggr   = []
    generic_errors = []

    # 1 — site connection status
    sites_res = ctx.run(
        ["curl", "-sk", "-u", auth,
         base + "/domain-types/site-connection/collections/all"],
        mutates=False,
    )

    if sites_res.rc != 0 or not sites_res.stdout.strip():
        generic_errors.append("cannot reach Checkmk API: " + sites_res.stderr.strip())
    else:
        sites_data = json.decode(sites_res.stdout)
        for entry in sites_data.get("value", []):
            ext      = entry.get("extensions", {})
            ls_state = ext.get("livestatus_state", "")
            site_id  = entry.get("id", "unknown")
            if ls_state != "" and ls_state != "online":
                missing_sites.append(site_id)

    # 2 — BI aggregation state (UNKNOWN == missing data from a site)
    bi_res = ctx.run(
        ["curl", "-sk", "-u", auth,
         base + "/domain-types/bi_aggregation/collections/all"],
        mutates=False,
    )

    if bi_res.rc == 0 and bi_res.stdout.strip():
        bi_data = json.decode(bi_res.stdout)
        for agg in bi_data.get("value", []):
            ext       = agg.get("extensions", {})
            agg_state = ext.get("state")
            agg_id    = agg.get("id", "unknown")
            # state 3 == UNKNOWN in Checkmk numeric encoding
            if agg_state == 3 or agg_state == "UNKNOWN":
                missing_aggr.append(agg_id)

    msgs         = []
    overall_state = "OK"

    if missing_sites:
        msgs.append("Unable to query data from site(s): " + ", ".join(sorted(missing_sites)))
        overall_state = "WARN"
    if missing_aggr:
        msgs.append("Unable to display aggregations because of missing data: " + ", ".join(sorted(missing_aggr)))
        overall_state = "WARN"
    if generic_errors:
        msgs.append("Error during data collection: " + ", ".join(generic_errors))
        overall_state = "WARN"

    if not msgs:
        msgs.append("No connection problems")

    return {
        "changed": False,
        "msg":     "; ".join(msgs),
        "data":    {"state": overall_state, "metrics": {}, "details": ""},
    }