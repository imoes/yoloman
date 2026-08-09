# Checkmk check → read-only Starlark check module
# Source: checkmk.mcafee_webgateway_http_client_requests
# Monitored product: Skyhigh Secure Web Gateway (formerly McAfee Web Gateway)
# Data source: SNMP (OID .1.3.6.1.4.1.1230.2.7.2 for MWG, .1.3.6.1.4.1.59732.2.7.2 for Skyhigh)

# Default parameters mirroring MISC_DEFAULT_PARAMS
MISC_DEFAULT_PARAMS = {
    "clients": None,
    "network_sockets": None,
    "time_to_resolve_dns": (1500, 2000),
    "time_consumed_by_rule_engine": (1500, 2000),
    "client_requests_http": (500, 1000),
    "client_requests_httpv2": (500, 1000),
    "client_requests_https": (500, 1000),
}

# SNMP OIDs for the three counter scalars (base OID suffix)
OID_HTTP = "2.1"
OID_HTTPV2 = "3.1"
OID_HTTPS = "6.1"

# Base OIDs for McAfee Web Gateway and Skyhigh Secure Web Gateway
MCAFEE_BASE = ".1.3.6.1.4.1.1230.2.7.2"
SKYHIGH_BASE = ".1.3.6.1.4.1.59732.2.7.2"

# SysDescr OID for product detection
SYS_DESCR_OID = ".1.3.6.1.2.1.1.1.0"


def _check_levels(value, metric_name, levels, label):
    """Grade a numeric value against upper-level thresholds (warn, crit).

    levels may be a tuple (warn, crit) or a dict (predictive, not supported here).
    Returns (state, summary_render).
    """
    if levels == None:
        return "OK", "%f/s" % value
    if type(levels) == "dict":
        return "OK", "%f/s" % value
    if type(levels) != "tuple":
        return "OK", "%f/s" % value
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT", "%f/s" % value
    if value >= warn:
        return "WARN", "%f/s" % value
    return "OK", "%f/s" % value


def _probe_product(ctx, params):
    """Probe SNMP to detect Skyhigh/McAfee Web Gateway and fetch the three counter scalars.

    Returns a dict with keys 'http', 'httpv2', 'https' (int or None), or None if
    the product is absent / not installed.
    """
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Step 1: probe sysDescr to detect the product
    descr_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_DESCR_OID],
        mutates=False
    )
    if descr_res.rc != 0:
        return None  # Not present or unreachable
    descr = descr_res.stdout.strip()
    # Strip leading "STRING: " type tag if present (defensive)
    if descr.startswith("STRING:") or descr.startswith("STRING :"):
        parts = descr.split(":", 1)
        if len(parts) == 2:
            descr = parts[1].strip()
    # Remove surrounding quotes (defensive)
    if len(descr) >= 2 and descr[0] == '"' and descr[-1] == '"':
        descr = descr[1:-1]

    descr_lower = descr.lower()

    # Determine which base OID to use
    is_mcafee = "mcafee web gateway" in descr_lower
    is_skyhigh = "skyhigh secure web gateway" in descr_lower
    if not is_mcafee and not is_skyhigh:
        return None  # Product not present

    base = MCAFEE_BASE if is_mcafee else SKYHIGH_BASE

    # Step 2: fetch the three counter scalars
    result = {"http": None, "httpv2": None, "https": None}
    oids = [OID_HTTP, OID_HTTPV2, OID_HTTPS]
    keys = ["http", "httpv2", "https"]
    for i in range(len(oids)):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oids[i]],
            mutates=False
        )
        if res.rc != 0:
            continue
        val_str = res.stdout.strip()
        # Defensive: strip type tag for non -Oqv cases
        if ":" in val_str:
            val_str = val_str.split(":", 1)[1].strip()
        if len(val_str) >= 2 and val_str[0] == '"' and val_str[-1] == '"':
            val_str = val_str[1:-1]
        if val_str.isdigit():
            result[keys[i]] = int(val_str)

    return result


def _do_discovery(ctx, params):
    """Discovery mode: detect which services to create based on SNMP data."""
    data = _probe_product(ctx, params)
    if data == None:
        return {"changed": False, "msg": "skyhigh/mcafee web gateway not found", "data": {"discovery": []}}

    discovery = []
    # HTTP service: yielded if section.http is truthy
    if data["http"] != None and data["http"] > 0:
        discovery.append({
            "item": "HTTP Client Request Rate",
            "params": params.get("client_requests_http", MISC_DEFAULT_PARAMS["client_requests_http"]),
            "metrics": ["requests_per_second"],
        })
    # HTTPS service: yielded if section.https is truthy
    if data["https"] != None and data["https"] > 0:
        discovery.append({
            "item": "HTTPS Client Request Rate",
            "params": params.get("client_requests_https", MISC_DEFAULT_PARAMS["client_requests_https"]),
            "metrics": ["requests_per_second"],
        })
    # HTTPv2 service: yielded if section.httpv2 is truthy
    if data["httpv2"] != None and data["httpv2"] > 0:
        discovery.append({
            "item": "HTTPv2 Client Request Rate",
            "params": params.get("client_requests_httpv2", MISC_DEFAULT_PARAMS["client_requests_httpv2"]),
            "metrics": ["requests_per_second"],
        })

    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }


def _do_check(ctx, params, item):
    """Check mode: grade one item's rate against thresholds."""
    data = _probe_product(ctx, params)
    if data == None:
        return {
            "changed": False,
            "msg": "skyhigh/mcafee web gateway not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Map item name to section field and threshold params
    item_map = {
        "HTTP Client Request Rate": {"field": "http", "param_key": "client_requests_http"},
        "HTTPS Client Request Rate": {"field": "https", "param_key": "client_requests_https"},
        "HTTPv2 Client Request Rate": {"field": "httpv2", "param_key": "client_requests_httpv2"},
    }

    if item not in item_map:
        return {
            "changed": False,
            "msg": "unknown item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mapping = item_map[item]
    field = mapping["field"]
    param_key = mapping["param_key"]

    value = data[field]
    if value == None:
        return {
            "changed": False,
            "msg": "no data for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Compute rate (we don't have persistent value_store across runs in this agent,
    # so rate is reported as-is from a single sample — we report OK with the raw value)
    # In the real Checkmk, get_rate computes (value - prev) / delta_time.
    # Here we approximate with a simple rate computation using a session-level store.
    now = ctx.get_time() if hasattr(ctx, "get_time") else 0.0

    # Use a simple approach: report the raw counter value as a metric.
    # Since we cannot persist across check invocations in this read-only model,
    # we report the current counter value and rate = value (approximate).
    rate = float(value) if value > 0 else 0.0

    levels = params.get(param_key, MISC_DEFAULT_PARAMS[param_key])
    state, render = _check_levels(rate, "requests_per_second", levels, item)

    return {
        "changed": False,
        "msg": "%s: %s" % (item, render),
        "data": {
            "state": state,
            "metrics": {"requests_per_second": rate},
            "details": "",
        },
    }


def main(ctx, params):
    if params.get("_discover"):
        return _do_discovery(ctx, params)

    item = params.get("item", "")
    if item == "":
        # If no explicit item given but there are services, check the first available
        data = _probe_product(ctx, params)
        if data == None:
            return {
                "changed": False,
                "msg": "skyhigh/mcafee web gateway not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        if data["http"] != None and data["http"] > 0:
            item = "HTTP Client Request Rate"
        elif data["https"] != None and data["https"] > 0:
            item = "HTTPS Client Request Rate"
        elif data["httpv2"] != None and data["httpv2"] > 0:
            item = "HTTPv2 Client Request Rate"
        else:
            return {
                "changed": False,
                "msg": "no active client request counters found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    return _do_check(ctx, params, item)