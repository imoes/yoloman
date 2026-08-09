# StoreOnce cluster info uptime check (read-only Starlark translation)
# Mirrors Checkmk check: storeonce_clusterinfo_uptime
# Source data: HPE StoreOnce REST API /cluster/system-info (the same data the
# Checkmk agent section <storeonce_clusterinfo> would expose via the
# storeonce special agent).

# State mapping for "Cluster Health Level" / "Replication Health Level"
# (level 0=OK, 1=warning, 2=critical) — mirrored from cmk.plugins.storeonce.lib
STATE_MAP = {0: "OK", 1: "WARN", 2: "CRIT"}


def _get_auth_header(params):
    token = params.get("api_token")
    if token:
        return {"Authorization": "Bearer " + token}
    return None


def _get_base_url(params):
    host = params.get("host", "localhost")
    protocol = params.get("protocol", "https")
    port = params.get("port", 443)
    return "%s://%s:%d/api/v1" % (protocol, host, port)


def _safe_float(s):
    if s == None or s == "":
        return None
    parts = s.split(".")
    if len(parts) > 2:
        return None
    for p in parts:
        if not p.lstrip("-").isdigit():
            return None
    return float(s)


def _collect_clusterinfo(ctx, params):
    base = _get_base_url(params)
    url = base + "/cluster/appliance"
    headers = _get_auth_header(params)

    argv = ["curl", "-sk", "-H", "Accept: application/json"]
    if headers:
        for k in sorted(headers):
            argv.extend(["-H", k + ": " + headers[k]])
    argv.append(url)

    res = ctx.run(argv, mutates=False)
    if res.rc != 0 or not res.stdout:
        return None

    data = json.decode(res.stdout)
    if type(data) != "dict":
        return None

    info = {}
    if "applianceName" in data:
        info["Appliance Name"] = str(data["applianceName"])
    if "serialNumber" in data:
        info["Serial Number"] = str(data["serialNumber"])
    if "softwareVersion" in data:
        info["Software Version"] = str(data["softwareVersion"])
    if "productClass" in data:
        info["Product Class"] = str(data["productClass"])

    # Uptime information — nested under system information in the REST API.
    sys_url = base + "/cluster/system"
    sys_argv = ["curl", "-sk", "-H", "Accept: application/json"]
    if headers:
        for k in sorted(headers):
            sys_argv.extend(["-H", k + ": " + headers[k]])
    sys_argv.append(sys_url)

    sys_res = ctx.run(sys_argv, mutates=False)
    if sys_res.rc != 0 or not sys_res.stdout:
        return None

    sys_data = json.decode(sys_res.stdout)
    if type(sys_data) != "dict":
        return None

    if "uptimeSeconds" in sys_data:
        info["Uptime Seconds"] = str(sys_data["uptimeSeconds"])
    if "clusterHealthLevel" in sys_data:
        info["Cluster Health Level"] = str(sys_data["clusterHealthLevel"])
    if "clusterHealth" in sys_data:
        info["Cluster Health"] = str(sys_data["clusterHealth"])
    if "clusterStatus" in sys_data:
        info["Cluster Status"] = str(sys_data["clusterStatus"])
    if "replicationHealthLevel" in sys_data:
        info["Replication Health Level"] = str(sys_data["replicationHealthLevel"])
    if "replicationHealth" in sys_data:
        info["Replication Health"] = str(sys_data["replicationHealth"])
    if "replicationStatus" in sys_data:
        info["Replication Status"] = str(sys_data["replicationStatus"])

    return info


def _probe_product_present(ctx, params):
    base = _get_base_url(params)
    url = base + "/cluster/appliance"
    argv = ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}", url]
    res = ctx.run(argv, mutates=False)
    if res.rc == 127:
        return False
    if res.skipped:
        return True
    code = res.stdout.strip()
    if code in ("401", "403", "200"):
        return True
    if code.startswith("4") or code.startswith("5"):
        return True
    return False


def main(ctx, params):
    if params.get("_discover"):
        if not _probe_product_present(ctx, params):
            return {"changed": False, "msg": "HPE StoreOnce not found",
                    "data": {"discovery": []}}

        section = _collect_clusterinfo(ctx, params)
        if section == None:
            return {"changed": False, "msg": "HPE StoreOnce API unreachable",
                    "data": {"discovery": []}}

        out = []
        if "Uptime Seconds" in section:
            out.append({"item": "", "params": {},
                        "metrics": ["uptime"]})

        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # Check mode: check one item (item "" for this single-service check).
    section = _collect_clusterinfo(ctx, params)
    if section == None or "Uptime Seconds" not in section:
        return {"changed": False,
                "msg": "HPE StoreOnce cluster info not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    uptime_val_str = section["Uptime Seconds"]
    uptime_seconds = _safe_float(uptime_val_str)
    if uptime_seconds == None:
        return {"changed": False,
                "msg": "invalid Uptime Seconds value: %s" % uptime_val_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply uptime thresholds from params (Checkmk uptime ruleset defaults).
    # warn = max age in days for warning; crit = max age for critical.
    # The uptime check reports CRIT when uptime < crit, WARN when uptime < warn.
    warn_age = params.get("warn")
    crit_age = params.get("crit")

    details = "Appliance: %s\nSerial: %s\nVersion: %s\nUptime: %f seconds" % (
        section.get("Appliance Name", "?"),
        section.get("Serial Number", "?"),
        section.get("Software Version", "?"),
        uptime_seconds,
    )

    state = "OK"
    if crit_age != None:
        crit_seconds = float(crit_age) * 86400
        if uptime_seconds < crit_seconds:
            state = "CRIT"
    if state == "OK" and warn_age != None:
        warn_seconds = float(warn_age) * 86400
        if uptime_seconds < warn_seconds:
            state = "WARN"

    # Format uptime into a human-readable string.
    days = int(uptime_seconds // 86400)
    hours = int((uptime_seconds % 86400) // 3600)
    minutes = int((uptime_seconds % 3600) // 60)
    seconds = int(uptime_seconds % 60)
    uptime_str = "%dd %dh %dm %ds" % (days, hours, minutes, seconds)

    msg = "Uptime: %s" % uptime_str
    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {"uptime": uptime_seconds},
                     "details": details}}